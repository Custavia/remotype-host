import AppKit
import IOKit.pwr_mgt

/// The ONE cast session per host (CASTING.md §10). Owns the state machine, the
/// 1 Hz `cast.status` ticker, the no-display-sleep power assertion, and lock
/// detection; drives a CastAirPlay for the NATIVE trigger/teardown. Process-
/// global: like the walk-away lock it deliberately SURVIVES connection
/// replacement — the Server pins its outbound frames to `castSessionOwner`
/// instead of tearing the session down with the socket.
final class CastSession {
    struct Target {
        let id: String
        let name: String
        let type: String
        var addr: String?
        var port: Int?
    }

    enum State: Equatable {
        case idle
        case starting(stage: String)   // resolving|launching|pin_required|connecting|guided|waiting_viewer
        case casting
        case paused(reason: String)    // locked
    }

    /// What KIND of cast this session drives. AIRPLAY is the slice-1 host-native
    /// (OS-mirror) path; BROWSER (§2.2 / §7.0) is the Tier-B0 MJPEG-over-LAN-HTTP
    /// path where the host serves its own receiver page and the phone only shows
    /// the URL/QR. One session type handles both so the ticker, power assertion,
    /// menu-bar name, and re-attach snapshot stay single-sourced; a BROWSER
    /// session skips ALL `airplay.*` calls (no AX / topology / PIN).
    /// CAST (§6.5 Tier 1) is the WebRTC-to-a-Cast-receiver path: the host is the
    /// media source (capture → H.264 → the Pion sidecar), the phone only relays
    /// SDP/ICE over `cast.sig`, and the receiver renders. Like BROWSER it has no
    /// AirPlay/AX/PIN, but unlike BROWSER it drives a real sink (the TV).
    enum Kind { case airplay, browser, cast }
    private(set) var kind: Kind = .airplay

    /// Outbound cast.* frames (status/ready/err/state) — the Server pins them
    /// to the session owner.
    var onFrame: (([String: Any]) -> Void)?
    /// Menu-bar "Casting to <TV>" name; nil clears it.
    var onTargetName: ((String?) -> Void)?
    /// PIN digits ride the existing injector path (the Server wires this).
    var typeText: ((String) -> Void)?
    /// BROWSER: live delivered fps from the HTTP server (informational, shown in
    /// `cast.status`). The Server wires it to `CastHTTPServer.fps`.
    var browserFPS: (() -> Int)?
    /// Fired at the END of teardown (every cause). The Server uses it to stop the
    /// full-display capture + close the browser HTTP server; a no-op for AIRPLAY.
    var onStopped: (() -> Void)?

    private let airplay = CastAirPlay()
    private(set) var state: State = .idle
    private(set) var sid: String?
    private(set) var target: Target?
    private var rid: String?          // consumed by the FIRST status (§8.7)
    private var audio = true
    private var quality = "auto"
    private var startedAt: Date?      // when CASTING was reached
    private var ticker: DispatchSourceTimer?
    private var triggerElapsed = 0    // seconds outside pin_required (30 s budget)
    private var guidedElapsed = 0     // seconds in guided (120 s window)
    private var lockedElapsed = 0     // seconds paused(locked) (15 min ceiling)
    private var stateBeforeLock: State?
    private var weInitiatedStop = false
    private var assertionID: IOPMAssertionID = 0
    private var caffeine: Process?   // holds the display awake for the cast (see wakeDisplay)
    private var lastLoggedKey: String?
    private var lockObservers: [NSObjectProtocol] = []
    // BROWSER-only: the receiver URL / short pairing code / session token echoed
    // in cast.ready + the re-attach snapshot (so a reconnecting phone re-shows
    // the QR), and the live viewer count driving waiting_viewer⇄casting.
    private var browserURL: String?
    private var browserCode: String?
    private var browserToken: String?
    private var browserViewers = 0
    // CAST-only: the §14.2 session token echoed in cast.ready + the re-attach
    // snapshot so a reconnecting phone can resume the cast.sig relay.
    private var castToken: String?

    /// §8.8 timing constants.
    static let triggerTimeout = 30
    static let guidedWindow = 120
    static let lockedCeiling = 15 * 60

    var isActive: Bool { state != .idle }

    init() {
        airplay.onPinRequired = { [weak self] in self?.enterPinRequired() }
        airplay.onTriggerFailed = { [weak self] in self?.enterGuided() }
        airplay.onPicked = { [weak self] in
            guard let self, case .starting(let stage) = self.state, stage == "launching" else { return }
            self.setState(.starting(stage: "connecting"))
            self.emitStatus()
        }
        airplay.onMirrorChange = { [weak self] active in self?.mirrorChanged(active) }
        let dnc = DistributedNotificationCenter.default()
        lockObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                                             object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked()
        })
        lockObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                             object: nil, queue: .main) { [weak self] _ in
            self?.screenUnlocked()
        })
    }

    deinit {
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        releaseAssertion()
        stopTicker()
    }

    // MARK: Lifecycle

    /// Begin a NATIVE (AirPlay) attempt. The Server enforces the §10.1
    /// busy/idempotent rules before calling; the first status answers the
    /// cast.start `rid` synchronously (well inside the 2 s contract).
    func start(rid: String, target: Target, audio: Bool, quality: String) {
        guard state == .idle else { return }
        kind = .airplay
        sid = String(format: "s%08x", UInt32.random(in: .min ... .max))
        self.rid = rid
        self.target = target
        self.audio = audio
        self.quality = quality
        weInitiatedStop = false
        triggerElapsed = 0
        guidedElapsed = 0
        lockedElapsed = 0
        startedAt = nil
        stateBeforeLock = nil
        onTargetName?(target.name)
        setState(.starting(stage: "resolving"))
        startTicker()
        emitStatus()
        onFrame?(["t": "cast.ready", "sid": sid!, "rid": rid, "path": "native",
                  "displays": Self.displayList(), "stream": ["kind": "native"]])
        setState(.starting(stage: "launching"))
        airplay.startTrigger(targetName: target.name)
    }

    /// Begin a BROWSER (Tier-B0) session (§7.0). The Server has already picked the
    /// LAN IP, generated the token/code, and started the HTTP server — here we
    /// only own the state machine: answer `cast.ready` with the URL/code (before
    /// any viewer connects, §8.4) and sit in `starting/waiting_viewer` until the
    /// first browser fetches the stream. No `airplay.*` — the phone is not in the
    /// media path and there is no sink to trigger/PIN.
    func startBrowser(rid: String, url: String, code: String, token: String,
                      audio: Bool, quality: String) {
        guard state == .idle else { return }
        wakeDisplay()   // capture is black on a sleeping display — wake it
        kind = .browser
        sid = String(format: "s%08x", UInt32.random(in: .min ... .max))
        self.rid = rid
        target = Target(id: "browser", name: "a browser", type: "browser", addr: nil, port: nil)
        self.audio = audio
        self.quality = quality
        browserURL = url
        browserCode = code
        browserToken = token
        browserViewers = 0
        weInitiatedStop = false
        startedAt = nil
        stateBeforeLock = nil
        onTargetName?("a browser")
        setState(.starting(stage: "waiting_viewer"))
        startTicker()
        // Ready first (URL/code the phone renders as a QR immediately), then the
        // first status (carries the `rid`, then it is consumed).
        onFrame?(["t": "cast.ready", "sid": sid!, "rid": rid, "path": "browser",
                  "token": token,
                  "stream": ["kind": "browser", "url": url, "code": code]])
        emitStatus()
    }

    /// Begin a CAST DIRECT (§6.5 Tier 1) session. The Server has resolved the sink,
    /// minted the token, and launched the sidecar (which will produce the WebRTC
    /// offer asynchronously — relayed over cast.sig, not here). We answer
    /// `cast.ready` synchronously (consuming the rid inside the 2 s contract) with
    /// the token + the sig channel, then sit in starting/connecting until the peer
    /// connects (`directConnected()`). No airplay/AX/PIN — the phone isn't in the
    /// media path; it only shuttles signaling.
    func startDirect(rid: String, target: Target, token: String, audio: Bool, quality: String) {
        guard state == .idle else { return }
        wakeDisplay()   // wake now so the display is on by the time capture starts
        kind = .cast
        sid = String(format: "s%08x", UInt32.random(in: .min ... .max))
        self.rid = rid
        self.target = target
        self.audio = audio
        self.quality = quality
        castToken = token
        weInitiatedStop = false
        startedAt = nil
        stateBeforeLock = nil
        onTargetName?(target.name)
        setState(.starting(stage: "connecting"))
        startTicker()
        onFrame?(["t": "cast.ready", "sid": sid!, "rid": rid, "path": "direct",
                  "token": token, "displays": Self.displayList(),
                  "stream": ["kind": "webrtc", "sigChannel": "cast.sig"]])
        emitStatus()
    }

    /// CAST: the sidecar's PeerConnection reached ICE-connected — media is flowing.
    /// Move to casting, hold the no-sleep assertion, start the elapsed clock.
    func directConnected() {
        guard kind == .cast, case .starting = state else { return }
        startedAt = startedAt ?? Date()
        holdAssertion()
        setState(.casting)
        emitStatus()
    }

    /// BROWSER: the HTTP server reports a viewer joined/left. Drives the
    /// waiting_viewer⇄casting(viewers:N) transition and re-emits status at once
    /// (a viewerless cast is NOT an error — the URL stays live).
    func setBrowserViewers(_ n: Int) {
        guard kind == .browser, isActive else { return }
        browserViewers = n
        updateBrowserPresence()
        emitStatus()
    }

    private func updateBrowserPresence() {
        switch state {
        case .idle, .paused:
            return   // locked: don't override; idle: nothing
        default:
            break
        }
        if browserViewers > 0 {
            if case .casting = state { return }
            startedAt = startedAt ?? Date()
            holdAssertion()          // held for the whole cast; released at teardown
            setState(.casting)
        } else {
            if case .starting(let s) = state, s == "waiting_viewer" { return }
            setState(.starting(stage: "waiting_viewer"))
        }
    }

    /// User-initiated stop (phone `cast.stop` or the menu-bar button): report
    /// stopped immediately, then best-effort script the OS mirror off.
    func stop() {
        guard isActive else { return }
        weInitiatedStop = true
        guard kind == .airplay else { finish(reason: "user"); return }   // BROWSER: no OS mirror to script off
        let name = target?.name
        let mirrorUp = airplay.mirrorActiveNow
        finish(reason: "user")
        if mirrorUp, let name { airplay.teardownMirror(targetName: name) }
    }

    /// Phone-typed AirPlay passcode → focus the dialog's field and inject.
    func pin(_ code: String, sid: String) {
        guard sid == self.sid, case .starting(let stage) = state, stage == "pin_required" else { return }
        HostLog.write("cast pin typed")   // never the code
        airplay.focusPinField()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.typeText?(code + "\n")
        }
        setState(.starting(stage: "connecting"))
        emitStatus()
        // A wrong code re-shows the dialog; if it is still up in a few seconds,
        // surface pin_required again rather than idling toward the timeout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, case .starting(let s) = self.state, s == "connecting",
                  self.airplay.pinFieldPresent else { return }
            self.enterPinRequired()
        }
    }

    /// The §8.4 re-attach snapshot, pushed unsolicited after every completed
    /// hello while a session exists. nil when idle.
    func stateSnapshot() -> [String: Any]? {
        guard let sid, let target else { return nil }
        let word: String
        switch state {
        case .idle: return nil
        case .starting: word = "starting"
        case .casting: word = "casting"
        case .paused: word = "paused"
        }
        if kind == .browser {
            // Re-attach for BROWSER: path + the SAME url/code/token so a
            // reconnecting phone re-shows the QR (§8.4-browser).
            var msg: [String: Any] = [
                "t": "cast.state", "sid": sid, "state": word, "path": "browser",
                "target": ["id": target.id, "name": target.name, "type": target.type],
                "startedAt": Int((startedAt ?? Date()).timeIntervalSince1970),
                "audio": audio, "quality": quality, "viewers": browserViewers]
            if let url = browserURL, let code = browserCode {
                msg["stream"] = ["kind": "browser", "url": url, "code": code]
            }
            if let browserToken { msg["token"] = browserToken }
            if case .starting(let stage) = state { msg["stage"] = stage }
            return msg
        }
        if kind == .cast {
            // Re-attach for CAST: path + target + token + sig channel so a
            // reconnecting phone can resume the cast.sig relay (§8.4).
            var msg: [String: Any] = [
                "t": "cast.state", "sid": sid, "state": word, "path": "direct",
                "target": ["id": target.id, "name": target.name, "type": target.type],
                "startedAt": Int((startedAt ?? Date()).timeIntervalSince1970),
                "audio": audio, "quality": quality,
                "stream": ["kind": "webrtc", "sigChannel": "cast.sig"]]
            if let castToken { msg["token"] = castToken }
            if case .starting(let stage) = state { msg["stage"] = stage }
            return msg
        }
        return ["t": "cast.state", "sid": sid, "state": word, "path": "native",
                "target": ["id": target.id, "name": target.name, "type": target.type],
                "display": Self.mainDisplayID(),
                "displays": Self.displayList(),
                "startedAt": Int((startedAt ?? Date()).timeIntervalSince1970),
                "audio": audio, "quality": quality]
    }

    // MARK: State machine internals

    /// Transitions-only logging (same gate as lastLoggedProximityPhase): the
    /// 1 Hz ticker must not flood the /tmp log. States/stages only — no names.
    private func setState(_ new: State) {
        state = new
        let key: String
        switch new {
        case .idle: key = "idle"
        case .starting(let stage): key = "starting \(stage)"
        case .casting: key = "casting"
        case .paused(let reason): key = "paused \(reason)"
        }
        if key != lastLoggedKey {
            lastLoggedKey = key
            HostLog.write("cast \(key)")
        }
    }

    private func emitStatus() {
        guard let sid, let target else { return }
        var msg: [String: Any] = ["t": "cast.status", "sid": sid]
        switch state {
        case .idle:
            return
        case .starting(let stage):
            msg["state"] = "starting"
            msg["stage"] = stage
        case .casting:
            msg["state"] = "casting"
        case .paused(let reason):
            msg["state"] = "paused"
            msg["reason"] = reason
        }
        if kind == .browser {
            // BROWSER: a friendly target label + the live viewer count (and fps
            // once casting). `waiting_viewer` keeps its stage above.
            msg["target"] = "a browser"
            msg["viewers"] = browserViewers
            if case .casting = state { msg["fps"] = browserFPS?() ?? 0 }
            msg["err"] = NSNull()
        } else {
            // NATIVE / CAST: the target name (no fps/kbps for native; cast reports
            // no per-frame stats this slice). Only NATIVE carries a display id.
            msg["target"] = target.name
            if kind == .airplay { msg["display"] = Self.mainDisplayID() }
        }
        if let rid {
            msg["rid"] = rid
            self.rid = nil
        }
        onFrame?(msg)
    }

    private func startTicker() {
        stopTicker()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        switch state {
        case .idle:
            return
        case .starting(let stage):
            // BROWSER `waiting_viewer` never times out — the URL stays live with
            // zero viewers. Only the AIRPLAY trigger/guided budgets apply.
            if kind == .airplay {
                if stage == "guided" {
                    guidedElapsed += 1
                    if guidedElapsed >= Self.guidedWindow {
                        stop()   // window expired → stopped(reason:"user") per §8.7
                        return
                    }
                } else if stage != "pin_required" {   // PIN-wait never counts (§9.2)
                    triggerElapsed += 1
                    if triggerElapsed >= Self.triggerTimeout {
                        enterGuided()
                        return
                    }
                }
            }
        case .paused(let reason):
            if reason == "locked" {
                lockedElapsed += 1
                if lockedElapsed >= Self.lockedCeiling {
                    stop()   // ceiling → stop, free the sink (§10.3)
                    return
                }
            }
        case .casting:
            break
        }
        emitStatus()
    }

    /// nomirror, same-room handling (§8.7): NOT terminal — the session stays
    /// STARTING(guided) for the 120 s window with the topology watcher armed,
    /// so a manual Control Center pick still completes the cast.
    private func enterGuided() {
        guard let sid, case .starting(let stage) = state, stage != "guided" else { return }
        airplay.cancelTrigger()
        guidedElapsed = 0
        onFrame?(["t": "cast.err", "sid": sid, "code": "nomirror",
                  "msg": "Couldn't start Screen Mirroring automatically — one quick step on your computer."])
        setState(.starting(stage: "guided"))
        emitStatus()
    }

    private func enterPinRequired() {
        guard case .starting(let stage) = state,
              stage == "launching" || stage == "connecting" else { return }
        setState(.starting(stage: "pin_required"))
        emitStatus()
    }

    private func mirrorChanged(_ active: Bool) {
        if active {
            guard case .starting = state else { return }
            airplay.cancelTrigger()
            airplay.stopPinWatcher()   // steady-state CASTING can't raise a passcode dialog (F29)
            startedAt = Date()
            holdAssertion()
            setState(.casting)
            emitStatus()
        } else {
            switch state {
            case .casting, .paused:
                // External stop (Control Center / TV side) — we didn't script it.
                if !weInitiatedStop { finish(reason: "user") }
            default:
                break
            }
        }
    }

    /// Teardown (§10.6, the NATIVE subset): stop watchers, release the power
    /// assertion, report `stopped`, clear state + the menu-bar item.
    private func finish(reason: String?) {
        guard isActive, let sid else { return }
        if kind == .airplay { airplay.stopWatchers() }
        releaseAssertion()
        var msg: [String: Any] = ["t": "cast.status", "sid": sid, "state": "stopped"]
        if let reason { msg["reason"] = reason }
        // BROWSER reports the friendly label; AIRPLAY the sink name.
        if kind == .browser { msg["target"] = "a browser" }
        else if let target { msg["target"] = target.name }
        onFrame?(msg)
        HostLog.write("cast stopped \(reason ?? "-")")
        stopTicker()
        state = .idle
        self.sid = nil
        target = nil
        rid = nil
        startedAt = nil
        stateBeforeLock = nil
        lastLoggedKey = nil
        browserURL = nil
        browserCode = nil
        browserToken = nil
        browserViewers = 0
        castToken = nil
        onTargetName?(nil)
        kind = .airplay          // reset default for the next session
        // Server-side teardown (stop capture + close the HTTP server); a no-op
        // for AIRPLAY (onStopped is only set for browser sessions).
        let stopped = onStopped
        onStopped = nil
        stopped?()
    }

    // MARK: Lock (§10.4)

    private func screenLocked() {
        // BROWSER: no pause-on-lock — the receiver keeps rendering (the phone is
        // not in the media path, and there is no sink to free). AIRPLAY only.
        guard isActive, kind == .airplay else { return }
        if case .paused = state { return }
        stateBeforeLock = state
        lockedElapsed = 0
        setState(.paused(reason: "locked"))
        emitStatus()
    }

    private func screenUnlocked() {
        guard case .paused(let reason) = state, reason == "locked" else { return }
        setState(stateBeforeLock ?? .casting)
        stateBeforeLock = nil
        emitStatus()
    }

    // MARK: Power assertion (§10.4)

    private func holdAssertion() {
        wakeDisplay()   // a still-asleep display must come on, not just stay on
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Remotype cast" as CFString, &id) == kIOReturnSuccess {
            assertionID = id
        }
    }

    /// Wake the local display AND keep it on for the whole cast, so ScreenCaptureKit
    /// captures the REAL screen. A cast started while the display is asleep otherwise
    /// captures BLACK — SCK delivers no frames on a sleeping display, so no HLS
    /// segments build and the TV shows black. `IOPMAssertionDeclareUserActivity`
    /// proved unreliable at turning an already-asleep display back on; `caffeinate
    /// -d -u` (Apple's own tool) does it reliably, held for the session, killed at
    /// teardown.
    func wakeDisplay() {
        guard caffeine == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d", "-u", "-t", "86400"]   // -u turns the display on; -d keeps it on
        do { try p.run(); caffeine = p } catch { HostLog.write("caffeinate failed") }
    }

    private func stopCaffeine() {
        caffeine?.terminate()
        caffeine = nil
    }

    private func releaseAssertion() {
        stopCaffeine()
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    // MARK: Displays (§6.1 list, NATIVE-informational)

    static func displayList() -> [[String: Any]] {
        NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            return ["id": String(id), "name": screen.localizedName,
                    "primary": CGDisplayIsMain(id) != 0]
        }
    }

    static func mainDisplayID() -> String { String(CGMainDisplayID()) }
}
