import Foundation
import CoreBluetooth

// Walk-away lock, host side.
//
// The phone advertises a BLE service with a rotating session token (see the
// iOS ProximityBeacon). The host scans for that service, connects, reads the
// token, verifies it matches the token it was ARMED with over the LAN, then
// polls the connection's RSSI ~every 1.5 s. Those samples drive a pure state
// machine (ProximityEvaluator) with hysteresis + a grace timer; when it says
// "lock", the host locks the screen.
//
// Two pieces, deliberately separated so the decision logic is testable
// WITHOUT CoreBluetooth or any device (this whole feature is DEVICE-UNTESTABLE
// in CI — see  for the validation risks):
//   • ProximityEvaluator — PURE. No CoreBluetooth, no timers, no side effects.
//     Feed it samples (or "no sample" ticks) + a clock; it returns a state and
//     a one-shot shouldLock edge. Fully unit-testable.
//   • ProximityMonitor   — the CoreBluetooth central that produces those
//     samples, owns the poll timer, performs the actual lock, and reports
//     state back to the Server via a callback.

// MARK: - Pure evaluator

/// Tuning for the evaluator. All RSSI values are dBm (negative; closer =
/// LESS negative / stronger). Defaults are documented at each field.
struct ProximityConfig: Equatable {
    /// The near/far boundary, in dBm, chosen by the phone's Sensitivity
    /// setting (Near −68 / Medium −78 / Far −88). The smoothed RSSI dropping
    /// below this for `graceSeconds` triggers the lock.
    var nearDbm: Int
    /// Seconds the smoothed signal must stay below threshold (or be lost)
    /// before locking. The phone's Delay setting (15/30/60). This is the
    /// PRIMARY guard against false locks: a momentary dip — a hand over the
    /// phone, a body between phone and Mac, a single noisy sample — never
    /// survives a multi-second grace window.
    var graceSeconds: Double
    /// Hysteresis margin, in dB. Once "leaving", the smoothed signal must
    /// climb back above `nearDbm + marginDb` (stronger by the margin) to count
    /// as "in range" again. RSSI hovers noisily ±5–8 dB even when the phone is
    /// still, so without this margin the state would flap across the boundary
    /// every sample and the grace timer would keep resetting. 8 dB is one
    /// typical noise band — wide enough to stop flapping, tight enough that a
    /// real return to the desk clears it. The SECOND false-lock guard.
    var marginDb: Int = 8
    /// EMA smoothing factor (0..1). Each new sample contributes `emaAlpha`;
    /// the running average keeps `1 - emaAlpha`. 0.4 ≈ a 3–4 sample window at
    /// the 1.5 s cadence (~5 s), which rides out single-sample spikes while
    /// still reacting within a few seconds to a genuine walk-off. The THIRD
    /// false-lock guard (smoothing) — works with grace + hysteresis, not
    /// instead of them.
    var emaAlpha: Double = 0.4
    /// How long without ANY sample before treating the link as signal-loss
    /// (the phone is out of range / Bluetooth dropped). At this point the
    /// evaluator stops waiting for a number and runs the grace timer toward a
    /// lock just as it would for a below-threshold signal. 5 s ≈ three missed
    /// 1.5 s polls. Signal LOSS is a legitimate walk-away path (you can walk
    /// far enough that the connection drops before RSSI crosses threshold).
    var lossTimeout: Double = 5
}

/// The coarse state the host reports to the phone and shows in its menu.
enum ProximityPhase: String, Equatable {
    case searching   // no usable sample yet (just armed / reconnecting)
    case inRange     // smoothed signal above threshold — phone is near
    case leaving     // below threshold or signal lost; grace timer counting
    case locked      // grace elapsed → the Mac was (or is being) locked
}

/// PURE proximity state machine. No CoreBluetooth, no timers, no I/O. Every
/// transition is a function of (previous state, this input, the clock). This
/// is the entire false-lock-avoidance logic, in one reviewable, unit-testable
/// place.
///
/// Transitions (let `s` = smoothed RSSI, `near` = config.nearDbm):
///   searching ──(s ≥ near)──────────────▶ inRange
///   searching ──(s < near or loss)──────▶ leaving   (start grace)
///   inRange   ──(s < near or loss)──────▶ leaving   (start grace)
///   inRange   ──(s ≥ near)──────────────▶ inRange   (stay; reset nothing)
///   leaving   ──(s ≥ near+margin)───────▶ inRange   (recovered; cancel grace)
///   leaving   ──(still <, grace not up)─▶ leaving   (keep counting)
///   leaving   ──(grace elapsed)─────────▶ locked    (emit shouldLock ONCE)
///   locked    ──(s ≥ near+margin)───────▶ inRange   (phone came back; re-arm)
///   locked    ──(anything else)─────────▶ locked    (stay; no repeat lock)
/// The hysteresis margin only applies to climbing OUT of leaving/locked — the
/// drop INTO leaving uses the bare threshold, so we react promptly to walking
/// off but resist flapping back.
struct ProximityEvaluator {
    let config: ProximityConfig

    private(set) var phase: ProximityPhase = .searching
    /// Running smoothed RSSI; nil until the first sample seeds it.
    private(set) var smoothed: Double?
    /// When the current `leaving` grace window started. nil outside `leaving`.
    private var leavingSince: Date?
    /// Timestamp of the last real sample — drives loss detection.
    private var lastSampleAt: Date?

    init(config: ProximityConfig) { self.config = config }

    /// The result of feeding one input: the (possibly unchanged) phase, plus a
    /// one-shot `shouldLock` that is true on EXACTLY the tick the machine
    /// crosses into `locked`. Callers lock on that edge and never again until
    /// the phone returns and re-leaves.
    struct Update: Equatable {
        let phase: ProximityPhase
        let shouldLock: Bool
        /// The smoothed RSSI rounded for reporting, or nil if none yet. Shown
        /// as a number on the host only — never sent to the phone as a secret
        /// (it isn't one), but the phone never displays it either.
        let smoothedRssi: Int?
    }

    /// Feed one RSSI sample taken at `now`.
    mutating func ingest(rssi: Int, now: Date) -> Update {
        lastSampleAt = now
        let s: Double
        if let prev = smoothed {
            s = prev + config.emaAlpha * (Double(rssi) - prev)
        } else {
            s = Double(rssi)   // seed: first sample is the average
        }
        smoothed = s
        return advance(signal: s, now: now)
    }

    /// Anchor the loss clock to the moment ranging begins — call this when a
    /// peripheral has been verified (token matched) and polling starts, even
    /// before any valid RSSI sample lands. Without it, a connect-then-no-valid-
    /// RSSI peer (every readRSSI errors, or the link goes silent right after
    /// verification) would leave `lastSampleAt == nil` forever, so `tick`'s
    /// loss branch never engages and the Mac never locks despite the phone
    /// being gone. Only seeds the clock; never overwrites a real sample's
    /// timestamp (those are always newer).
    mutating func beginRanging(now: Date) {
        if lastSampleAt == nil { lastSampleAt = now }
    }

    /// Feed a "no sample this tick" — used when readRSSI() yields nothing or a
    /// poll is missed. After `lossTimeout` with no sample this is treated as
    /// signal loss and counts toward the grace window like a weak signal.
    mutating func tick(now: Date) -> Update {
        let lost: Bool
        if let last = lastSampleAt {
            lost = now.timeIntervalSince(last) >= config.lossTimeout
        } else {
            lost = false   // never had a sample → still "searching", not "lost"
        }
        // Pass the smoothed value through; `lost` forces the below-threshold
        // branch regardless of the last good number.
        return advance(signal: smoothed, now: now, lost: lost)
    }

    /// Core transition. `signal` = current smoothed RSSI (nil if none yet);
    /// `lost` = forced signal-loss (no recent sample).
    private mutating func advance(signal: Double?, now: Date, lost: Bool = false) -> Update {
        let near = Double(config.nearDbm)
        let reentry = Double(config.nearDbm + config.marginDb)   // stronger by margin

        // No usable signal yet and not a loss → keep searching.
        guard let s = signal else {
            if lost { return enterLeaving(now: now) }
            return Update(phase: phase, shouldLock: false, smoothedRssi: nil)
        }

        // Forced loss always drives toward leaving/locked.
        if lost {
            return enterLeaving(now: now, smoothedOverride: s)
        }

        switch phase {
        case .searching:
            if s >= near {
                phase = .inRange
                leavingSince = nil
                return Update(phase: .inRange, shouldLock: false, smoothedRssi: rounded(s))
            } else {
                return enterLeaving(now: now, smoothedOverride: s)
            }

        case .inRange:
            if s < near {
                return enterLeaving(now: now, smoothedOverride: s)
            }
            leavingSince = nil
            return Update(phase: .inRange, shouldLock: false, smoothedRssi: rounded(s))

        case .leaving:
            // Recover only past the hysteresis margin — resist flapping.
            if s >= reentry {
                phase = .inRange
                leavingSince = nil
                return Update(phase: .inRange, shouldLock: false, smoothedRssi: rounded(s))
            }
            // Still below: has the grace window elapsed?
            if let since = leavingSince,
               now.timeIntervalSince(since) >= config.graceSeconds {
                phase = .locked
                return Update(phase: .locked, shouldLock: true, smoothedRssi: rounded(s))
            }
            return Update(phase: .leaving, shouldLock: false, smoothedRssi: rounded(s))

        case .locked:
            // Phone came back strongly → re-arm to inRange (no auto-unlock; the
            // user unlocks the Mac themselves — we just resume watching).
            if s >= reentry {
                phase = .inRange
                leavingSince = nil
            }
            return Update(phase: phase, shouldLock: false, smoothedRssi: rounded(s))
        }
    }

    /// Enter (or stay in) `leaving`, starting the grace clock on the first
    /// transition. If already `locked`, stay locked (no repeat). If already
    /// counting and the window elapsed, this is where loss-driven locks fire.
    private mutating func enterLeaving(now: Date, smoothedOverride: Double? = nil) -> Update {
        let s = smoothedOverride ?? smoothed
        switch phase {
        case .locked:
            return Update(phase: .locked, shouldLock: false, smoothedRssi: rounded(s))
        case .leaving:
            if let since = leavingSince,
               now.timeIntervalSince(since) >= config.graceSeconds {
                phase = .locked
                return Update(phase: .locked, shouldLock: true, smoothedRssi: rounded(s))
            }
            return Update(phase: .leaving, shouldLock: false, smoothedRssi: rounded(s))
        default:
            phase = .leaving
            leavingSince = now
            return Update(phase: .leaving, shouldLock: false, smoothedRssi: rounded(s))
        }
    }

    private func rounded(_ v: Double?) -> Int? { v.map { Int($0.rounded()) } }
}

// MARK: - CoreBluetooth monitor

/// Drives a ProximityEvaluator from live BLE RSSI and performs the lock.
/// Owns a CBCentralManager, the connected peripheral, and a ~1.5 s poll timer.
/// Everything runs on .main (the queue handed to CBCentralManager and the
/// Server's queue) so there's no cross-thread state.
///
/// Lifecycle invariant (mirrors VitalsSampler/Server's timer rule): the
/// central, the peripheral, and the timer must NEVER outlive an arming. `stop()`
/// tears all three down and is called on disarm and host quit; `start(...)`
/// fully resets before (re)arming.
final class ProximityMonitor: NSObject {

    /// Poll cadence for readRSSI(). 1.5 s matches the vitals stream — frequent
    /// enough to react within the grace window, light enough to barely cost
    /// battery on either side.
    private static let pollInterval: TimeInterval = 1.5

    /// Reported back to the Server on every phase change (and each poll), so it
    /// can emit `{"t":"prox"}` frames and update the menu. `rssi` is the
    /// smoothed value (or nil) — the Server may show it as a number; it is
    /// never a secret and the phone never displays it.
    var onState: ((ProximityPhase, _ rssi: Int?) -> Void)?

    /// How long to wait for a committed candidate peripheral to connect,
    /// discover, and read back its token before giving up on it and rescanning.
    /// Without this watchdog a connect/discover/read that silently stalls (a
    /// wrong phone winning the scan and answering slowly, or a GATT handshake
    /// that never completes) would strand the monitor with `peripheral` non-nil
    /// — so didDiscover ignores the real phone, the poll timer never starts,
    /// and the loss path never engages. 6 s comfortably covers a real GATT
    /// round-trip while bounding a wedge.
    private static let verifyTimeout: TimeInterval = 6

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tokenCharacteristic: CBCharacteristic?
    private var pollTimer: DispatchSourceTimer?
    /// One-shot watchdog for the connect→discover→read-token sequence; fires
    /// if a committed candidate doesn't verify in time so another (the real
    /// phone) can be tried. Cancelled the moment a token is verified.
    private var verifyTimer: DispatchSourceTimer?
    /// True once the current peripheral's token matched `armedToken` and we
    /// began ranging. Distinguishes "committed but still verifying" (watchdog
    /// armed) from "verified, polling RSSI" (watchdog cancelled).
    private var verified = false
    private var evaluator: ProximityEvaluator?

    /// The token (raw bytes) we were armed with — the phone's current session
    /// token. A connected peripheral is only accepted once its token
    /// characteristic reads back EXACTLY this, so we never range against some
    /// other Remotype phone that happens to be advertising the same (public)
    /// service UUID.
    private var armedToken: Data?
    private var config = ProximityConfig(nearDbm: -78, graceSeconds: 30)
    /// True between start() and stop(); guards async CB callbacks that may fire
    /// after teardown.
    private var armed = false

    // MARK: Public control

    /// (Re)arm the monitor against `token` with `config`.
    ///
    /// IDEMPOTENT re-arm: if we're already armed against the SAME token and the
    /// SAME config, this is a no-op — the running central, the connected
    /// peripheral, the poll timer, and (crucially) the evaluator's phase are
    /// all KEPT. The phone re-sends prox.arm on every (re)connect/host-switch,
    /// and a single reconnect can fire several near-simultaneous arms; without
    /// this guard each one would stop()/rebuild the whole CoreBluetooth stack,
    /// flapping the status back to `searching` on every link blip and — worse —
    /// resetting a `.locked` phase out to `.searching`, which can drive a
    /// SECOND lock for the very same departure (re-arm to inRange is meant to
    /// require `s ≥ near+margin`, not a re-arm message). The arming is supposed
    /// to persist seamlessly across a TCP blip; an unchanged re-arm must not
    /// disturb the live BLE state machine at all.
    ///
    /// A genuinely NEW arming (rotated token) tears the old central down and
    /// starts clean from `searching`, so a fresh session is ranged correctly.
    func start(token: Data, config: ProximityConfig) {
        if armed, armedToken == token, self.config == config {
            return   // identical re-arm: keep the running central/evaluator/timer
        }
        stop()
        armed = true
        armedToken = token
        self.config = config
        evaluator = ProximityEvaluator(config: config)
        onState?(.searching, nil)
        // A fresh central each arm: simplest correct lifecycle (no lingering
        // scan/connection state from a prior token). The delegate's
        // didUpdateState kicks off scanning once it's powered on.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Tear everything down. Safe to call when not armed. Called on prox.disarm,
    /// on a replacing arm, and on app quit — the central/peripheral/timer must
    /// never outlive an arming.
    func stop() {
        armed = false
        armedToken = nil
        evaluator = nil
        pollTimer?.cancel()
        pollTimer = nil
        verifyTimer?.cancel()
        verifyTimer = nil
        verified = false
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        if let central, central.isScanning {
            central.stopScan()
        }
        peripheral = nil
        tokenCharacteristic = nil
        central = nil
    }

    // MARK: Poll loop

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.armed else { return }
            // Feed a tick on EVERY fire, regardless of connection state. The
            // evaluator ignores ticks while a recent ingest keeps lastSampleAt
            // fresh, so this is harmless when samples are flowing — but it is
            // load-bearing when they are NOT: a peer that is `.connected` at
            // L2CAP yet has gone silent (a backgrounded/suspended iOS
            // peripheral that stops answering readRSSI) would otherwise feed
            // neither a sample nor a tick, freezing the evaluator at its last
            // phase and never locking. With a tick every poll, lastSampleAt
            // simply stops advancing and loss accrues toward the grace window.
            self.feed { $0.tick(now: Date()) }
            // readRSSI() is a side request: a successful reply lands in
            // didReadRSSI and advances lastSampleAt via ingest (which the tick
            // then defers to). If the reply never arrives, ticks keep coming.
            if let p = self.peripheral, p.state == .connected {
                p.readRSSI()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Run one evaluator transition and react to its verdict.
    private func feed(_ body: (inout ProximityEvaluator) -> ProximityEvaluator.Update) {
        guard armed, evaluator != nil else { return }
        let update = body(&evaluator!)
        onState?(update.phase, update.smoothedRssi)
        if update.shouldLock {
            ScreenLock.lock()
        }
    }
}

extension ProximityMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard armed else { return }
        if central.state == .poweredOn {
            central.scanForPeripherals(
                withServices: [ProximityIDs.serviceUUID],
                // Don't allow duplicates — we connect once and poll RSSI on the
                // connection, not via repeated advertisement sightings.
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        // poweredOff/unauthorized: leave phase as-is; the Server's status line
        // and the loss timeout handle the "can't see the phone" case.
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard armed, self.peripheral == nil else { return }
        // Connect to read the token before trusting any RSSI from it. We do NOT
        // range off the advertisement RSSI — the token must match first.
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
        // Bound the whole connect→discover→read-token sequence. If this
        // candidate doesn't verify in time (CoreBluetooth's connect has no
        // implicit timeout, and discovery/read can silently stall), drop it and
        // rescan so the real phone can win next time.
        startVerifyWatchdog()
    }

    /// Arm the connect-and-verify watchdog for the currently committed
    /// `peripheral`. Cancelled on token verification. On expiry, drop the
    /// candidate and rescan (resetPeripheralAndRescan), which also cancels the
    /// pending GATT connection — so a wedged candidate can't permanently block
    /// the real phone.
    private func startVerifyWatchdog() {
        verifyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.verifyTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.armed, !self.verified else { return }
            // Still unverified after the window → give up on this candidate.
            self.resetPeripheralAndRescan()
        }
        timer.resume()
        verifyTimer = timer
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        guard armed else { return }
        peripheral.discoverServices([ProximityIDs.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetPeripheralAndRescan()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // The link dropped — a legitimate walk-away path. Keep feeding ticks
        // (the poll timer does) so the loss timeout drives toward a lock, and
        // rescan in case the phone comes back into range.
        resetPeripheralAndRescan()
    }

    /// Drop the current peripheral and resume scanning (still armed). The poll
    /// timer keeps running and now feeds `tick` (no connection) so signal-loss
    /// accrues toward the grace window.
    private func resetPeripheralAndRescan() {
        verifyTimer?.cancel()
        verifyTimer = nil
        verified = false
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)   // drop a wedged/wrong link
        }
        peripheral = nil
        tokenCharacteristic = nil
        guard armed, let central, central.state == .poweredOn else { return }
        if !central.isScanning {
            central.scanForPeripherals(
                withServices: [ProximityIDs.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
}

extension ProximityMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard armed, error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == ProximityIDs.serviceUUID })
        else { resetPeripheralAndRescan(); return }
        peripheral.discoverCharacteristics([ProximityIDs.tokenCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard armed, error == nil,
              let char = service.characteristics?.first(where: {
                  $0.uuid == ProximityIDs.tokenCharacteristicUUID })
        else { resetPeripheralAndRescan(); return }
        tokenCharacteristic = char
        peripheral.readValue(for: char)   // verify the token before ranging
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard armed, error == nil,
              characteristic.uuid == ProximityIDs.tokenCharacteristicUUID else { return }
        // Verify the token matches what we were armed with — otherwise this is a
        // different phone advertising the same public service UUID. Drop it and
        // keep scanning for the right one.
        guard let value = characteristic.value, value == armedToken else {
            resetPeripheralAndRescan()
            return
        }
        // Verified. Cancel the connect-and-verify watchdog and begin ranging.
        verified = true
        verifyTimer?.cancel()
        verifyTimer = nil
        // Anchor the loss clock to NOW (ranging start), not the first
        // successful sample: if every readRSSI on this connection errors or the
        // link goes silent right after verification, sustained loss must still
        // accrue toward the grace window and lock. Without this, lastSampleAt
        // would stay nil and tick()'s loss branch would never engage.
        evaluator?.beginRanging(now: Date())
        // Kick the poll loop and take an immediate first reading so we don't
        // wait a full interval to leave `searching`.
        startPolling()
        peripheral.readRSSI()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber, error: Error?) {
        guard armed else { return }
        if error != nil {
            feed { $0.tick(now: Date()) }   // a failed read = no sample
            return
        }
        let rssi = RSSI.intValue
        feed { $0.ingest(rssi: rssi, now: Date()) }
    }
}

// MARK: - Shared identifiers (must match the iOS ProximityBeacon)

/// The fixed, PUBLIC BLE identifiers. Same strings as the iOS side's
/// ProximityBeacon — every Remotype phone advertises this one service; the
/// rotating per-session token (read from `tokenCharacteristicUUID`) is the
/// only varying datum, and it is never advertised.
enum ProximityIDs {
    static let serviceUUID = CBUUID(string: "B5C9A2E4-1F7D-4A36-9E0B-7C2D8F5A41E9")
    static let tokenCharacteristicUUID = CBUUID(string: "B5C9A2E5-1F7D-4A36-9E0B-7C2D8F5A41E9")
}

// MARK: - Screen lock

/// Locks the Mac screen immediately. Primary path is the private
/// `SACLockScreenImmediate` symbol in login.framework (resolved once via
/// dlopen/dlsym, exactly like VitalsSampler resolves MediaRemote); if that
/// symbol is unavailable, fall back to `pmset displaysleepnow`, which sleeps
/// the display and (with "require password after sleep" on — the default)
/// locks the Mac.
///
/// DEVICE-UNTESTABLE / VALIDATION RISK: `SACLockScreenImmediate`
/// is a private, undocumented symbol; its availability across macOS versions
/// is not guaranteed and must be validated on real hardware. The pmset
/// fallback is the safety net but only locks if the user has password-after-
/// sleep enabled.
enum ScreenLock {
    private typealias LockFn = @convention(c) () -> Int32

    /// Resolved once, lazily. nil if the framework/symbol is missing.
    private static let sacLock: LockFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_LAZY),
            let sym = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(sym, to: LockFn.self)
    }()

    static func lock() {
        if let fn = sacLock {
            _ = fn()
            return
        }
        // Fallback: sleep the display (locks if password-after-sleep is on).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["displaysleepnow"]
        try? proc.run()
    }
}
