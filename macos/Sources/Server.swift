import Foundation
import Network
import ApplicationServices
import AppKit
import Combine

/// Advertises `_hsbtk._tcp` over Bonjour, accepts a TCP connection from the iOS
/// app, decodes newline-delimited JSON events and feeds them to the [Injector].
final class Server: ObservableObject {
    @Published var listening = false
    /// The port actually bound, surfaced in the menu. Not cosmetic: when 50808 is
    /// taken the host silently comes up somewhere else, and Connect-by-IP and
    /// Tailscale both dial 50808 — so the one number that explains "my phone
    /// can't reach this Mac" was the one number nothing displayed.
    @Published var listenPort: UInt16? = nil
    @Published var clientName: String? = nil
    @Published var accessibilityTrusted = false
    /// Screen Recording (TCC) grant — needed ONLY for TV mode, the
    /// live magnified screen feed. Distinct from Accessibility: reading the
    /// cursor/caret/geometry needs no permission, only the screen PIXELS do.
    @Published var screenRecordingTrusted = false
    /// What the TCC database says, as distinct from what THIS process can do.
    ///
    /// The `…Trusted` pair above is the live capability — it gates injection and
    /// capture, and on current macOS it can stay false for the life of the
    /// process after the user grants, because the preflight answers are cached
    /// at first ask. These two are refreshed through the `--tcc-probe` child
    /// (see `TCCProbe`), which is born after the grant and therefore reads it.
    /// granted && !trusted is exactly one state: "allowed — restart to apply",
    /// and the wizard renders it as such instead of waiting forever.
    @Published var accessibilityGranted = false
    @Published var screenGranted = false
    @Published var lastEvent: String = "—"

    private let injector = Injector()
    /// Spotlight overlay: the click-through screen overlay the
    /// phone drives. Self-contained (just a window) — not gated on Accessibility
    /// — but v2-gated like every other control event. `reset()` on every client
    /// teardown path so a dropped phone never leaves the Mac dimmed.
    private let overlay = OverlayController()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    /// Vitals stream: sampler + the 1.5 s repeating timer that
    /// pushes `{"t":"vitals"}` frames while the phone is subscribed. The
    /// subscription is per-connection — the timer must never outlive its
    /// subscriber, so every teardown path calls `stopVitals()`.
    private let vitals = VitalsSampler()
    private var vitalsTimer: DispatchSourceTimer?
    /// TV mode: the magnified screen-feed capture. Per-connection
    /// like vitals — `stopTV()` on every teardown path. `tvSubscriber` pins
    /// frames to the connection that subscribed (same hole-closing as vitals).
    private let capture = CaptureController()
    private var tvSubscriber: NWConnection?
    // TV-frame backpressure: at most one frame in flight, newest-wins. Without
    // this the host blasts 30 fps fire-and-forget; on a slow link (Tailscale /
    // cellular) that saturates the connection — the picture freezes AND the
    // input it shares the link with stalls (the trackpad/keyboard look dead).
    private var tvSendInFlight = false
    private var tvSendGen = 0          // identifies the in-flight frame send, for the stuck-send deadline
    private var tvPendingFrame: Data?
    /// Computer audio: the system-audio tap. Per-connection like the
    /// TV capture — `stopAudio()` on every teardown path; `audioSubscriber` pins
    /// PCM chunks to the connection that subscribed.
    private let audioCapture = AudioCapture()
    private var audioSubscriber: NWConnection?
    /// MCM edge-flow (MCM.md §3): polls the cursor only while armed, reports edge
    /// hits, warps/parks on switch. `edge.disarm()` on every teardown path.
    private lazy var edge: EdgeDetector = {
        let e = EdgeDetector()
        e.onEdge = { [weak self] side, y in self?.send(["t": "edge", "side": side, "y": y]) }
        e.onCancel = { [weak self] in self?.send(["t": "edge.cancel"]) }
        return e
    }()
    /// Walk-away lock: the BLE central + RSSI evaluator that
    /// locks the Mac when the phone walks away. Armed by `prox.arm`, torn down
    /// by `prox.disarm` and on app quit. Unlike vitals, the arming deliberately
    /// SURVIVES a TCP drop (a brief link blip mustn't unlock the walk-away
    /// guard); see the accept() / teardown notes below.
    private let proximity = ProximityMonitor()
    /// The latest phase the monitor reported — surfaced in the menu bar so the
    /// user can see "Walk-away lock: armed/locked/off" on the Mac itself.
    @Published var proximityArmed = false
    @Published var proximityPhase: ProximityPhase? = nil
    /// The connection that issued the live `prox.arm` (always a v2-helloed
    /// client — arming is gated on it). Outbound `prox` frames are PINNED to
    /// this connection so a phone's coarse in-range/leaving/locked state and
    /// its smoothed RSSI never stream to a different phone or an unauthenticated
    /// socket that merely became `self.connection` after the owner's link
    /// dropped. Re-pinned on each (re)arm; cleared on disarm. A reconnecting
    /// same phone re-arms and re-pins; a foreign/pre-hello socket gets nothing.
    private var proximityArmer: NWConnection?
    /// The last phase actually written to HostLog/lastEvent. The monitor calls
    /// onState every poll (~1.5 s) even when the phone just sits in range;
    /// logging each would flood the append-only /tmp log (~57k lines/day) and
    /// rewrite the menu's "Last:" line at that cadence. Gate the log + lastEvent
    /// on a real phase TRANSITION; the prox frame still goes out every poll for
    /// phone-side freshness.
    private var lastLoggedProximityPhase: ProximityPhase?
    /// Screen casting (CASTING.md, slice 1): host-side sink discovery + the
    /// one NATIVE (AirPlay) session per host. The scan subscription is
    /// per-connection like vitals; the SESSION is process-global and — like
    /// the walk-away lock — deliberately survives connection replacement.
    private let castDiscovery = CastDiscovery()
    private let castSession = CastSession()
    /// Browser cast (CASTING.md §7.0, Tier B0): a SECOND full-display capture
    /// (`.full` mode, native/capped res — NOT the small magnified TV lens) whose
    /// JPEG frames are fanned out to LAN browsers by the token-scoped HTTP server.
    /// Both are tied to the browser SESSION, not the phone connection — so, like
    /// the cast session, they SURVIVE accept()/link-drop and are torn down only
    /// on cast.stop / menu Stop / quit (via castSession.onStopped).
    private let browserCapture = CaptureController()
    /// A SECOND audio tap dedicated to browser cast (separate from the phone's
    /// TV-mode `audioCapture` so the two never fight over start/stop). Runs only
    /// while a browser has "Enable sound" on.
    private let browserAudio = AudioCapture()
    private var browserHTTP: CastHTTPServer?
    /// A just-stopped browser server still in its 410 grace; held so the next
    /// cast can reclaim the fixed port (force-closed on a new start).
    private var browserHTTPGracing: CastHTTPServer?
    /// Cast DIRECT (§6.5 Tier 1): the WebRTC sidecar bridge, the VideoToolbox
    /// encoder feeding it, a dedicated full-display capture (raw sink, not JPEG),
    /// and a STEREO audio tap (§6.2). Like the browser serve, all four are tied to
    /// the SESSION and survive link-drop — torn down only via castSession.onStopped.
    private var castWebRTC: CastWebRTC?
    private var castEncoder: CastEncoder?
    private let castCapture = CaptureController()
    private let castAudio = AudioCapture(stereo: true)
    private let castAudioAAC = CastAudioAAC()   // Tier-3 HLS: PCM → AAC-LC ADTS
    /// The active DIRECT session's §14.2 token — every inbound cast.sig must match
    /// it (constant-time) before we relay the SDP/ICE to the sidecar.
    private var castToken: String?
    /// Auto-stops a cast whose phone (owner) dropped and never reconnected — so a
    /// killed/vanished phone can't strand the sink casting forever.
    private var castOwnerGraceTimer: DispatchWorkItem?
    /// The connection subscribed via `cast.scan.sub`; `cast.targets` snapshots
    /// are pinned to it. Torn down on every connection teardown path.
    private var castScanSubscriber: NWConnection?
    /// The connection entitled to the session's outbound cast frames (status/
    /// state/err). Pinned on cast.start; RE-pinned on every completed hello
    /// while a session exists (the re-attach push) — a replacement socket gets
    /// nothing until it hellos, and the session itself never dies with the link.
    private var castSessionOwner: NWConnection?
    /// The active session's sink name, for the menu bar's "Casting to <TV> —
    /// Stop" row (the only stop affordance that survives a dead phone).
    @Published var castTargetName: String? = nil
    /// Protocol version from the current connection's `hello` (0 = no hello
    /// yet). Gates the clipboard bridge: a raw socket that never introduced
    /// itself must not be able to read (or poison) the Mac's clipboard.
    private var clientHelloVersion = 0
    /// Per-connection RT1 state. Replaced on every accept, so a frame from a
    /// previous connection can never decrypt against the new key schedule.
    private var rt1 = RT1Session()
    /// RT1 fields carried on the hello. Stashed by the handshake reader because
    /// `InputEvent.hello` has no room for them, and keeping them on the hello
    /// rather than in an extra message keeps the handshake at one round trip.
    private var helloRT1: (tag: String, nonce: String, epk: String)?
    /// Connections on PROBATION: a newcomer that arrived while an already-open
    /// session held the slot. Each carries its OWN session + buffer so nothing
    /// it does touches the incumbent; it graduates only by completing its own
    /// session handshake (proving a paired key), at which point promotePending
    /// performs the real, authenticated hand-off. This is what stops an unpaired
    /// LAN socket from evicting the paired phone merely by connecting.
    private final class Pending {
        let conn: NWConnection
        let rt1 = RT1Session()
        var buffer = Data()
        var helloVersion = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    /// Set when a phone too old for RT1 connects. See the hello handler.
    @Published var legacyPhoneName: String?

    // The Bonjour instance name IS what the phone lists — a bare "Remotype Host"
    // told users nothing once two computers were on the LAN. Windows always
    // appended the computer name; the Mac now matches.
    private let clipFile = ClipFile()

    let serviceName = "Remotype Host (\(Host.current().localizedName ?? "Mac"))"

    /// Protocol version answered in `hi` (see PROTOCOL.md).
    static let protocolVersion = 2
    /// clip replies (and inbound clip.set, defensively) refuse payloads
    /// beyond this many UTF-8 bytes.
    static let clipboardByteCap = 64 * 1024

    init() {
        refreshAccessibility()
        refreshScreenRecording()
        // The monitor reports phase changes here; we both update the menu's
        // status and emit a `prox` frame to the phone that armed us. The
        // monitor already runs its CBCentralManager + poll timer on .main and
        // calls onState synchronously on .main, so we do NOT hop to .main again
        // — a second hop could let a callback produced just before stop() land
        // AFTER a disarm cleared the phase, re-setting it. The `armed` guard
        // below ignores any straggler.
        proximity.onState = { [weak self] phase, rssi in
            guard let self, self.proximityArmed else { return }
            self.proximityPhase = phase
            // The frame goes out every poll for phone-side freshness, but the
            // HostLog write + menu "Last:" line only fire on a real transition
            // — otherwise an in-range phone heartbeats the log every ~1.5 s.
            if phase != self.lastLoggedProximityPhase {
                self.lastLoggedProximityPhase = phase
                // Never log the token; the phase word is fine, rssi is not logged.
                HostLog.write("proximity \(phase.rawValue)")
                self.lastEvent = "proximity \(phase.rawValue)"
            }
            // PINNED to the arming connection (always v2): the owner's coarse
            // state + smoothed RSSI must not stream to a replacement phone or an
            // unauthenticated socket. With no pinned armer there is nobody
            // entitled to the frame — never fall back to broadcasting it (a
            // nil `from:` would do exactly that). send() also drops the frame
            // if the pinned connection is no longer the current one.
            guard let armer = self.proximityArmer else { return }
            var msg: [String: Any] = ["t": "prox", "state": phase.rawValue]
            if let rssi { msg["rssi"] = rssi }
            self.send(msg, from: armer)
        }
        castDiscovery.onChange = { [weak self] items in
            // Full snapshot on every change, pinned to the scan subscriber.
            guard let self, let subscriber = self.castScanSubscriber else { return }
            self.send(["t": "cast.targets", "items": items], from: subscriber)
        }
        castSession.onFrame = { [weak self] obj in
            // With no pinned owner there is nobody entitled to the frame —
            // never fall back to broadcasting it (same rule as prox frames).
            guard let self, let owner = self.castSessionOwner else { return }
            self.send(obj, from: owner)
        }
        castSession.onTargetName = { [weak self] name in
            self?.castTargetName = name
        }
        castSession.typeText = { [weak self] s in
            // The AirPlay passcode rides the existing literal-text path.
            self?.injector.handle(.text(string: s, del: 0))
        }
        start()
    }

    deinit {
        // The listener (and with it the Server) only goes away when the app
        // does — belt and braces: cancel the vitals timer and the proximity
        // monitor explicitly rather than relying on dealloc ordering. The BLE
        // central / poll timer must never outlive the app.
        stopVitals()
        stopTV()
        stopAudio()
        edge.disarm()
        stopCastScan()
        castSession.stop()   // release the power assertion / OS mirror on quit; onStopped tears down browser/cast serve
        browserCapture.stop()   // belt and braces — the full-display capture must never outlive the app
        browserAudio.stop()
        browserHTTP?.stop()
        castCapture.stop()   // belt and braces for the cast path (encoder/sidecar/tap)
        castAudio.stop()
        castAudioAAC.stop()
        castEncoder?.stop()
        castWebRTC?.stop()
        proximity.stop()
    }

    /// Re-read the injection grant, as this process experiences it.
    ///
    /// The gate is `CGPreflightPostEventAccess()` ALONE, because it is the exact
    /// capability the host uses — posting CGEvents. `AXIsProcessTrusted()` must
    /// NOT be ANDed in: it caches false for the life of the process on a fresh
    /// grant while post-event access may already be true.
    ///
    /// Do not trust this to turn true on a fresh grant AT ALL, though: on
    /// current macOS the preflight answer itself can be cached from the first
    /// ask, so a host that was running while the user flipped the switch may
    /// never see it here. That is what `refreshFreshGrants()` (the child-process
    /// probe) is for, and why `accessibilityGranted` exists separately. This
    /// value stays authoritative for what injection can do RIGHT NOW, and it
    /// does flip false promptly on revocation.
    func refreshAccessibility() {
        let was = accessibilityTrusted
        accessibilityTrusted = CGPreflightPostEventAccess()
        if accessibilityTrusted { accessibilityGranted = true }
        if accessibilityTrusted != was { sendPerms() }   // tell the phone the moment it flips
    }

    /// Ask the TCC database — not this process's cached view of it — whether the
    /// grants are in, by spawning `RemotypeHost --tcc-probe` and reading the exit
    /// mask. Throttled and coalesced: the wizard calls this from a 0.6 s tick,
    /// and one short-lived child every ~2 s is the actual cost.
    private var probeInFlight = false
    private var lastProbeAt = Date.distantPast
    func refreshFreshGrants() {
        guard !probeInFlight, Date().timeIntervalSince(lastProbeAt) > 2 else { return }
        guard let exe = Bundle.main.executableURL else { return }
        probeInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--tcc-probe"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var mask: Int32 = -1   // spawn failure must not read as "revoked"
            do { try p.run(); p.waitUntilExit(); mask = p.terminationStatus } catch {}
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                self.lastProbeAt = Date()
                guard mask >= 0 else { return }
                // Injection is possible with EITHER bit: the AX-list entry or a
                // separate post-event grant. A fresh process gets both right.
                self.accessibilityGranted =
                    (mask & (TCCProbe.axBit | TCCProbe.postEventBit)) != 0 || self.accessibilityTrusted
                self.screenGranted =
                    (mask & TCCProbe.screenBit) != 0 || self.screenRecordingTrusted
            }
        }
    }

    /// Clear this app's TCC entries so macOS prompts fresh, then RELAUNCH.
    ///
    /// macOS keys Accessibility / Screen Recording to the app's CODE SIGNATURE.
    /// Reinstall or re-sign the host and the old entry survives as a stale
    /// record: the toggle still looks enabled but no longer matches this binary,
    /// so injection silently fails. `tccutil reset <service> <bundle-id>` removes
    /// it for the current user, no admin rights needed.
    ///
    /// The relaunch is NOT optional. `AXIsProcessTrusted()` caches its answer for
    /// the life of the process, so after a reset the running app still reports
    /// "granted" while every event it posts is dropped on the floor — the menu
    /// lies, Recheck agrees with the lie (it calls the same cached API), and the
    /// user is left with a host that looks healthy and types nothing. A fresh
    /// process re-evaluates trust honestly and the Grant button works again.
    func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.custavia.remotype.host"
        for service in ["Accessibility", "ScreenCapture"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, bundleID]
            try? p.run()
            p.waitUntilExit()
        }
        HostLog.write("permissions reset (\(bundleID)) — relaunching")
        lastEvent = "permissions reset — relaunching"
        relaunch()
    }

    /// Quit and come back.
    ///
    /// Needed in two places for the same underlying reason: several TCC answers
    /// are decided for the life of the PROCESS. After a `tccutil reset` the
    /// running app still reports "granted" while every event it posts is
    /// dropped; after a fresh Screen Recording grant it is the other way round —
    /// the switch is on and the capture it starts is still refused. Only a new
    /// process sees the truth in either direction.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Prompt the user to grant Accessibility (needed to post events). Also opens
    /// the System Settings pane — the one-time AX prompt is suppressed after the
    /// first ask, so without this the menu button looks dead on a re-grant.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Separate gate, separate prompt: post-event access can be missing even
        // when the AX list shows us enabled, and only this call re-asks for it.
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        openSecurityPane("Privacy_Accessibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshAccessibility() }
    }

    /// Re-read the Screen Recording grant (no prompt) — mirrors refreshAccessibility,
    /// including the caveat: a fresh grant may only be visible to the probe.
    func refreshScreenRecording() {
        let was = screenRecordingTrusted
        screenRecordingTrusted = CGPreflightScreenCaptureAccess()
        if screenRecordingTrusted { screenGranted = true }
        if screenRecordingTrusted != was { sendPerms() }
    }

    // MARK: Permissions report (phone warning + per-item Fix)

    /// The host's permission state, for the phone's warning badge + Fix modal.
    /// `required` ⇒ a hard gate (typing/pointer won't work without it); `fixable`
    /// ⇒ the host can jump to the right System Settings pane on `perm.fix`.
    private func permsItems() -> [[String: Any]] {
        [
            // `pane` is what the switch's own window is CALLED on this Mac. The
            // phone draws a picture of that window, and it had been guessing the
            // title from the permission's name — which is right for
            // Accessibility and wrong for Screen Recording, whose pane macOS
            // renamed to "Screen & System Audio Recording". The host is the only
            // side that can know; older hosts omit it and the phone falls back.
            ["id": "accessibility", "name": "Accessibility", "granted": accessibilityTrusted,
             "required": true, "fixable": true,
             "pane": "Accessibility",
             "detail": "Lets Remotype type and move the pointer on this Mac."],
            ["id": "screen", "name": "Screen Recording", "granted": screenRecordingTrusted,
             "required": false, "fixable": true,
             "pane": "Screen & System Audio Recording",
             "detail": "Needed for TV screen-mirror and computer audio."],
        ]
    }

    /// Push the current permission state to the phone (on connect, on change, and
    /// after a Fix). No-op when nobody's connected.
    func sendPerms() { send(["t": "perms", "items": permsItems()]) }

    /// `perm.fix` from the phone: open the matching System Settings pane (and fire
    /// the one-time system prompt so the app is listed), then re-report shortly so
    /// the phone's badge clears once the user grants it.
    func fixPermission(_ id: String) {
        switch id {
        case "accessibility":
            requestAccessibility()
            openSecurityPane("Privacy_Accessibility")
        case "screen":
            requestScreenRecording()
            openSecurityPane("Privacy_ScreenCapture")
        default:
            return
        }
        for delay in [2.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAccessibility()
                self?.refreshScreenRecording()
                self?.sendPerms()
            }
        }
    }

    private func openSecurityPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prompt for Screen Recording (TV mode). Unlike Accessibility this needs an
    /// app RELAUNCH to take effect — the badge won't flip until restart — so the
    /// menu copy says as much. Refresh after a beat to catch an already-granted
    /// state (the prompt no-ops then).
    func requestScreenRecording() {
        // CGRequestScreenCaptureAccess() shows the system prompt AT MOST ONCE and is
        // silently suppressed afterwards — so on a re-grant the button does nothing.
        // Open the Settings pane too (where the toggle actually lives; takes effect
        // on the host's next relaunch).
        _ = CGRequestScreenCaptureAccess()
        openSecurityPane("Privacy_ScreenCapture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshScreenRecording() }
    }

    /// Remotype's well-known TCP port. Bonjour advertises whatever port we bind,
    /// so discovery works regardless — but Connect-by-IP (Tailscale/VPN, where
    /// mDNS can't traverse) needs a STABLE port the user can dial. We bind this
    /// one when free, falling back to an OS-assigned port if it's taken.
    static let preferredPort: UInt16 = 50808

    func start() {
        startNetworkWatch()
        startListener(on: NWEndpoint.Port(rawValue: Self.preferredPort))
    }

    /// How many times the fixed port is retried before giving up on it. An UPDATE
    /// is the case that matters: the outgoing host is asked to quit and the new
    /// one starts immediately, but the old socket can outlive the process by a
    /// moment — so the first bind loses a race it would win a second later. Before
    /// this, every in-place update silently demoted the host to an OS-assigned
    /// port, which quietly breaks Connect-by-IP and Tailscale (both of which dial
    /// 50808) until the next restart, with nothing on screen to say why.
    private static let preferredPortRetries = 6      // ~3s at 500ms
    private var portAttempts = 0

    /// Watches the network path so a Wi-Fi switch, a cable pull or a VPN coming
    /// up is SEEN and logged rather than silently wedging a session. Callbacks
    /// run on their own queue and only hop to main to publish state — nothing
    /// here ever blocks the main thread, touches CoreWLAN, or restarts the
    /// listener (the listener is bound to any-interface; mDNSResponder
    /// re-registers it per interface on its own).
    private var pathMonitor: NWPathMonitor?
    private var lastPathSummary = ""
    /// Keeps the process out of App Nap while it is a server. App Nap throttles
    /// timers and can defer drawing for a background app that has been idle for
    /// hours — the menu-bar popover coming up unpainted is one face of it — and
    /// a host that must answer a phone instantly should never nap. The option
    /// deliberately ALLOWS idle system sleep: the Mac still sleeps normally.
    private var activityToken: NSObjectProtocol?

    private func startNetworkWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ifaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ",")
            let summary = "\(path.status) \(ifaces.isEmpty ? "no interfaces" : ifaces)"
            DispatchQueue.main.async {
                guard let self, summary != self.lastPathSummary else { return }
                let first = self.lastPathSummary.isEmpty
                self.lastPathSummary = summary
                guard !first else { return }          // the initial report is not a change
                HostLog.write("network changed: \(summary)")
                self.lastEvent = path.status == .satisfied ? "network changed" : "network down"
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.custavia.remotype.host.path"))
        pathMonitor = monitor
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Remotype Host is listening for phones")
        }
    }

    /// Start the listener on [port] (nil = OS-assigned). A bind failure on the
    /// fixed port is retried for a few seconds before falling back to ephemeral,
    /// so Bonjour still works even in the genuinely-occupied case.
    private func startListener(on port: NWEndpoint.Port?) {
        do {
            let params = NWParameters.tcp
            // NEVER peer-to-peer. `includePeerToPeer` makes the listener ride
            // AWDL (Apple's peer-to-peer Wi-Fi) as well as the LAN — and a
            // third-party process holding AWDL in play is the well-known way
            // to wedge a Mac's Wi-Fi association when the user switches
            // networks ("trying to connect…" until a reboot). Phones reach this
            // host over the same Wi-Fi or Tailscale; P2P buys nothing here.
            params.includePeerToPeer = false
            params.allowLocalEndpointReuse = true   // tolerate a quick relaunch
            let listener = port != nil ? try NWListener(using: params, on: port!)
                                       : try NWListener(using: params)
            listener.service = NWListener.Service(
                name: serviceName, type: "_hsbtk._tcp",
                txtRecord: NWTXTRecord(["os": "mac"]))
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.listening = (state == .ready)
                    switch state {
                    case .ready:
                        self.portAttempts = 0
                        if let p = listener.port {
                            self.listenPort = p.rawValue
                            HostLog.write("listening on port \(p.rawValue)")
                        }
                    case .failed:
                        guard port != nil else { break }
                        listener.cancel()
                        if self.portAttempts < Self.preferredPortRetries {
                            self.portAttempts += 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.startListener(on: NWEndpoint.Port(rawValue: Self.preferredPort))
                            }
                        } else {
                            // Genuinely occupied by something else. Say so LOUDLY:
                            // this state is otherwise indistinguishable from health,
                            // and it is the one that breaks dialling by address.
                            HostLog.write("port \(Self.preferredPort) is in use by another program — "
                                + "falling back to an OS-assigned port. Connect-by-IP and Tailscale "
                                + "will need the port shown in Activity.")
                            self.startListener(on: nil)
                        }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("RemotypeHost: listener failed: \(error)")
            if port != nil { startListener(on: nil) }   // retry ephemeral
        }
    }

    private func accept(_ conn: NWConnection) {
        NSLog("RemotypeHost: accept new connection")
        HostLog.write("accept connection")
        // Vet before swap. If a session is ALREADY OPEN, a newcomer must prove
        // itself before it can take the slot: otherwise any unpaired socket on
        // the LAN disconnects the paired phone the instant it connects (the
        // guard stops it CONTROLLING anything, but not from kicking). Put it on
        // probation — its own session + buffer, none of the incumbent's state —
        // and let promotePending do the hand-off only if it authenticates. With
        // no open session to protect (first connect, or the current socket never
        // authenticated) the old immediate-takeover behaviour stands.
        if connection != nil, rt1.isOpen {
            beginProbation(conn)
            return
        }
        // Single active client: replace any prior one. The replaced
        // connection's .cancelled handler sees `connection !== conn` and skips
        // its cleanup — so its vitals subscription must be stopped here.
        stopVitals()
        stopTV()
        stopAudio()
        edge.disarm()
        stopCastScan()
        // The overlay is per-connection (unlike walk-away lock): a new client
        // starts with a clean screen, and a phone that vanished can't leave the
        // Mac dimmed behind a replacement.
        overlay.reset()
        // The CAST SESSION is DELIBERATELY NOT stopped here (same survival rule
        // as the walk-away lock, NOT the tv/aud teardown): the OS mirror is
        // host↔TV and must outlive a phone link blip or replacement. Its
        // outbound frames stay pinned to castSessionOwner — a pre-hello
        // replacement socket gets nothing — and the owner re-pins on the next
        // completed hello (which pushes cast.state for re-attach) or cast.start.
        // Only cast.stop, the menu-bar Stop, guided/pause expiry, or an
        // external mirror stop tears the session down.
        // Walk-away lock is DELIBERATELY NOT stopped here. Its arming is meant
        // to survive a TCP drop (a brief link blip must not unlock the
        // walk-away guard); only prox.disarm, a replacing prox.arm, or app
        // quit tears it down. CHOSEN BEHAVIOR on a fresh client that connects
        // but never re-arms: the running monitor is KEPT (it keeps ranging the
        // previously-armed token and locking on walk-away). The common case —
        // the same phone reconnecting — re-hellos and re-arms, which restarts
        // the monitor with its rotated token harmlessly. A brand-new *different*
        // phone that hellos but never arms can't read the old phone's token
        // characteristic (token mismatch → the monitor just keeps scanning), so
        // it doesn't get walk-away frames it didn't ask for; the prior guard
        // simply persists until explicitly disarmed.
        connection?.cancel()
        connection = conn
        buffer.removeAll()
        clientHelloVersion = 0   // the handshake is per-connection
        // RT1 is per-connection too, and this line is load-bearing. `Server`
        // keeps ONE `rt1` because it keeps one active connection — so without
        // this, a replacement socket inherits the previous phone's OPEN session
        // and its key schedule. The visible symptom is a fresh phone whose very
        // first plaintext hello is read as a sealed frame and fails to decrypt,
        // closing the link before it can say anything; the real one is that the
        // guard is asking about a session that belongs to somebody else.
        rt1 = RT1Session()
        helloRT1 = nil
        legacyPhoneName = nil
        DispatchQueue.main.async { PairingCode.shared.noteDisconnected() }
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: break
                case .failed, .cancelled:
                    if self?.connection === conn {
                        // The socket that began a pairing went away before
                        // finishing it, and without a pair.cancel — a drop, not
                        // a decision. Same outcome for the code, gentler words.
                        if self?.rt1.isPairing == true, PairingCode.live != nil {
                            PairingCode.shared.endedByPhone(message: "The phone disconnected before pairing finished",
                                                            reason: "phone disconnected mid-pairing")
                        }
                        self?.connection = nil
                        self?.clientName = nil
                        self?.injector.releaseAllModifiers()
                        self?.stopVitals()   // subscription dies with its connection
                        self?.stopTV()       // capture dies with its connection
                        self?.stopAudio()    // audio tap dies with its connection
                        self?.edge.disarm()  // edge poll dies with its connection
                        self?.stopCastScan() // scan dies with its connection — the SESSION survives (see accept())
                        self?.overlay.reset()   // never leave the Mac dimmed after a drop
                        // The cast SESSION survives a link blip (the phone reconnects
                        // and re-pins), but if NO phone comes back it must not strand
                        // the sink casting forever with no control — arm an auto-stop.
                        if self?.castSession.isActive == true { self?.armCastOwnerGrace() }
                    }
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                NSLog("RemotypeHost: received \(data.count) bytes")
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    /// Framing never changes: split on newlines, exactly as before RT1. What
    /// changes is what a line CONTAINS once the handshake completes — a base64
    /// sealed blob instead of JSON. Keeping the framing is what let this land
    /// without touching the overflow guards, the teardown paths, the newest-wins
    /// TV pump or either coalescing outbox.
    private func drainLines() {
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let line = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            guard !line.isEmpty else { continue }

            var json = line
            if rt1.isOpen {
                do { json = try rt1.open(line: line) }
                catch {
                    // A line that will not decrypt means the peer is out of
                    // step or someone is probing. Close, silently: an error
                    // frame here would be a decryption oracle.
                    HostLog.write("RT1: sealed line failed to open — closing")
                    connection?.cancel()
                    return
                }
            } else if handleHandshake(line: json) {
                continue
            }
            guard let event = InputEvent.parse(json) else { continue }
            apply(event)
        }
    }

    // MARK: Probation (vet before swap)

    private func beginProbation(_ conn: NWConnection) {
        let p = Pending(conn)
        pending[ObjectIdentifier(conn)] = p
        HostLog.write("RT1: a second connection arrived while a session is open — vetting it before any hand-off")
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    // Drop it. The incumbent is untouched — the whole point.
                    self.pending.removeValue(forKey: ObjectIdentifier(conn))
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receivePending(p)
        // A prober that never authenticates must not sit forever. A real
        // reconnect finishes in well under a second; give it a generous window,
        // then drop it — the open session stays.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak conn] in
            guard let self, let conn, self.pending[ObjectIdentifier(conn)] != nil else { return }
            HostLog.write("RT1: a probationary connection never authenticated — dropping it, the open session stays")
            conn.cancel()
        }
    }

    private func receivePending(_ p: Pending) {
        p.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                p.buffer.append(data)
                self.drainPending(p)
            }
            if isComplete || error != nil { p.conn.cancel(); return }
            // Stop reading once it graduated (promoted) or was dropped.
            if self.pending[ObjectIdentifier(p.conn)] != nil { self.receivePending(p) }
        }
    }

    /// A plaintext line straight to ONE connection, bypassing send()'s
    /// self.connection guard — for probation replies, which are all pre-open
    /// (pong / hi / rt.ok) and belong to a socket that is deliberately NOT the
    /// active one yet.
    private func sendPlain(_ obj: [String: Any], to conn: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    /// The narrow handshake a probationary connection may run: a ping (liveness)
    /// and the session handshake of an ALREADY-PAIRED device (hello → hi →
    /// rt.conf). It never pairs a new device (that would show a code while
    /// another phone is in control) and never injects — everything else is
    /// ignored, and it never touches the incumbent. On rt.conf opening its own
    /// session it graduates via promotePending.
    private func drainPending(_ p: Pending) {
        let newline = UInt8(ascii: "\n")
        while let idx = p.buffer.firstIndex(of: newline) {
            let line = p.buffer.subdata(in: p.buffer.startIndex..<idx)
            p.buffer.removeSubrange(p.buffer.startIndex...idx)
            guard !line.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let t = obj["t"] as? String else { continue }
            switch t {
            case "ping":
                sendPlain(["t": "pong"], to: p.conn)
            case "hello":
                guard obj["rt"] != nil,
                      let tag = obj["tag"] as? String,
                      let n = obj["n"] as? String,
                      let epk = obj["epk"] as? String else {
                    // A legacy / no-RT1 hello can't authenticate, so it can't
                    // take over an open session. Say nothing; it times out.
                    continue
                }
                p.helloVersion = (obj["v"] as? Int) ?? 0
                let (fields, failure) = p.rt1.beginSession(tagB64: tag, noncePhoneB64: n, epkPhoneB64: epk)
                if failure != nil {
                    // Not a device we know. Don't offer to pair on a probation
                    // socket. It times out; the incumbent is undisturbed.
                    continue
                }
                var hi: [String: Any] = ["t": "hi", "v": Self.protocolVersion,
                                         "name": Host.current().localizedName ?? "Mac",
                                         "os": "mac", "cast": 1, "browser": 1, "audio": 1,
                                         "direct": CastWebRTC.isAvailable ? 1 : 0]
                fields.forEach { hi[$0.key] = $0.value }
                sendPlain(hi, to: p.conn)
            case "rt.conf":
                let reply = p.rt1.confirmSession(macB64: obj["mac"] as? String ?? "")
                sendPlain(reply, to: p.conn)          // rt.ok is plaintext (RT1 §3)
                if p.rt1.isOpen { promotePending(p); return }
            default:
                continue   // guard: a probation socket does nothing else
            }
        }
    }

    /// The probationary connection completed its session handshake, so it holds
    /// a paired device's key and may take the slot. THIS is the only place a
    /// live session is torn down for a newcomer — an authenticated hand-off, not
    /// an anonymous eviction.
    private func promotePending(_ p: Pending) {
        pending.removeValue(forKey: ObjectIdentifier(p.conn))
        let conn = p.conn

        // The same per-connection teardown accept() runs on a takeover: the
        // outgoing phone's subscriptions/capture must not outlive it.
        stopVitals(); stopTV(); stopAudio(); edge.disarm(); stopCastScan()
        overlay.reset()

        connection?.cancel()          // evict the incumbent — now justified
        connection = conn
        rt1 = p.rt1                   // already OPEN
        buffer = p.buffer            // any bytes queued after rt.conf
        clientHelloVersion = p.helloVersion
        helloRT1 = nil
        legacyPhoneName = nil

        // From here it is an ordinary active connection: give it the standard
        // teardown handler in place of the probation one.
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: break
                case .failed, .cancelled:
                    if self?.connection === conn {
                        self?.connection = nil
                        self?.clientName = nil
                        self?.injector.releaseAllModifiers()
                        self?.stopVitals()
                        self?.stopTV()
                        self?.stopAudio()
                        self?.edge.disarm()
                        self?.stopCastScan()
                        self?.overlay.reset()
                        if self?.castSession.isActive == true { self?.armCastOwnerGrace() }
                    }
                default: break
                }
            }
        }

        // The open side-effects rt.conf normally runs — deferred on the
        // probation socket so an un-promoted prober triggered none of them.
        if let name = rt1.device?.name {
            clientName = name
            lastEvent = "connected: \(name)"
            DispatchQueue.main.async { PairingCode.shared.noteConnected(name) }
            HostLog.write("RT1: session open with \(name) (took over from the previous phone)")
            refreshAccessibility(); refreshScreenRecording(); sendPerms()
            if castSession.isActive, let snap = castSession.stateSnapshot() {
                castSessionOwner = connection
                castOwnerGraceTimer?.cancel(); castOwnerGraceTimer = nil
                send(snap, from: connection)
            }
        }
        receive(on: conn)
        drainLines()   // process any bytes that arrived after rt.conf
    }

    /// The only messages accepted before a connection is open. Returns true when
    /// the line was a handshake message and must not go any further.
    ///
    /// Everything else on an unopened connection is dropped by the guard at the
    /// top of `apply`. Before RT1 this was the hole: injection, `clip.file.pull`
    /// and two events accidentally left out of the v2 gate all reached their
    /// handlers on a socket that had proved nothing.
    private func handleHandshake(line: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let t = obj["t"] as? String else { return false }

        switch t {
        case "pair.begin":
            let dev = obj["dev"] as? String ?? ""
            let spk = obj["spk"] as? String ?? ""
            let epk = obj["epk"] as? String ?? ""
            let name = obj["name"] as? String ?? "a phone"
            let plat = obj["plat"] as? String ?? "?"
            var code = PairingCode.live
            if code == nil {
                // No code showing: mint one HERE, synchronously, so this very
                // pair.begin is answered pair.hi with a real code — one tap on
                // the phone, and the code is on the Mac's screen with the phone
                // already asking for it (matching the Windows host, which has
                // raised its window on every begin since it shipped). The mint
                // touches only the lock-guarded code Box; the panel, the
                // @Published mirror and the expiry timer are main-actor state,
                // brought into line by adoptMinted() on the main queue right
                // after. The receive runs OFF the main actor, so the earlier
                // MainActor.assumeIsolated here trapped and pairing minted no
                // code at all — this is that regression's fix.
                code = PairingCode.mintForHandshake()
                DispatchQueue.main.async {
                    PairingCode.shared.adoptMinted()
                    PairingWindow.present()
                }
            } else if let code {
                // A code was already live and we are reusing it. Keep the test
                // hook in step with reality (no-op in shipped builds).
                PairingCode.writeTestHook(code)
            }
            let reply = rt1.beginPairing(dev: dev, spkPhoneB64: spk, epkPhoneB64: epk,
                                         name: name, platform: plat, code: code,
                                         hostName: Host.current().localizedName ?? "Mac")
            send(reply, from: connection)
            return true

        case "pair.cancel":
            // The user tapped Cancel on the phone. Retire the code and SAY SO
            // on the Mac: a window still showing a code nobody is typing reads
            // as "still waiting", when the truth is that the phone walked away.
            if rt1.isPairing {
                rt1.cancelPairing()
                DispatchQueue.main.async {
                    PairingCode.shared.endedByPhone(message: "Pairing was cancelled on phone",
                                                    reason: "cancelled on the phone")
                }
            }
            return true

        case "pair.conf":
            let (reply, paired) = rt1.confirmPairing(macB64: obj["mac"] as? String ?? "")
            if let paired {
                DispatchQueue.main.async {
                    PairingCode.shared.noteSuccess(deviceName: paired.name)
                    PairedDevices.shared.refresh()
                }
            } else {
                DispatchQueue.main.async { PairingCode.shared.noteFailure() }
            }
            send(reply, from: connection)
            return true

        case "rt.conf":
            let reply = rt1.confirmSession(macB64: obj["mac"] as? String ?? "")
            send(reply, from: connection, plaintext: true)
            if rt1.isOpen, let name = rt1.device?.name {
                clientName = name
                lastEvent = "connected: \(name)"
                DispatchQueue.main.async { PairingCode.shared.noteConnected(name) }
                HostLog.write("RT1: session open with \(name)")
                // Everything the old hello used to trigger, now that the peer
                // has actually proved who it is.
                refreshAccessibility(); refreshScreenRecording(); sendPerms()
                if castSession.isActive, let snap = castSession.stateSnapshot() {
                    castSessionOwner = connection
                    castOwnerGraceTimer?.cancel(); castOwnerGraceTimer = nil
                    send(snap, from: connection)
                }
            }
            return true

        case "hello":
            // Stash the RT1 fields, then let the hello continue down the normal
            // path — which already knows how to answer one.
            if obj["rt"] != nil,
               let tag = obj["tag"] as? String,
               let n = obj["n"] as? String,
               let epk = obj["epk"] as? String {
                helloRT1 = (tag: tag, nonce: n, epk: epk)
            }
            return false

        default:
            return false
        }
    }

    /// Reply path back to the phone: one compact JSON object + `\n`. Always
    /// hops onto the connection's queue (.main — where the connection was
    /// started), so it's safe to call from anywhere; a silent no-op when no
    /// client is attached. Pass `from:` to pin the frame to the connection it
    /// was meant for: the async hop means the current client can change
    /// between enqueue and execution, and a timer-driven frame must never
    /// land on a brand-new pre-hello connection.
    /// `plaintext: true` is for exactly one frame — `rt.ok`, the host's last
    /// unsealed line (RT1 §3). By the time this closure runs the session is
    /// already open, so without the flag it would be sealed with counter 0 and
    /// the phone, still reading plaintext, would see line noise.
    private func send(_ obj: [String: Any], from subscriber: NWConnection? = nil,
                      plaintext: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let conn = self.connection,
                  subscriber == nil || subscriber === conn,
                  let json = try? JSONSerialization.data(withJSONObject: obj)
            else { return }

            var data: Data
            if self.rt1.isOpen && !plaintext {
                // Sealing MUST happen here, on the connection's own queue, and
                // nowhere else: the counter is sequential, and two frames sealed
                // concurrently would reach the phone out of counter order and
                // break its decryption permanently — not just for those frames.
                guard let sealed = try? self.rt1.seal(json: json) else {
                    HostLog.write("RT1: could not seal an outbound frame — closing")
                    conn.cancel()
                    return
                }
                data = sealed
            } else {
                data = json
            }
            data.append(0x0A)
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// THE GUARD. `apply` has exactly one call site, so this line is the only
    /// place every inbound message must pass through — and therefore the only
    /// placement that cannot be bypassed.
    ///
    /// It has to be here, above everything, because the messages that mattered
    /// most were the ones handled EARLIEST: injection fell through both switches
    /// to the tail, `clip.file.pull` was dispatched before the v2 gate and could
    /// send a file off the machine, and `tv.pan` and `ovl.timer` were left out
    /// of the gate's case lists by accident. A check anywhere inside those
    /// switches would have covered none of them.
    private func apply(_ event: InputEvent) {
        if !rt1.isOpen {
            // Two exceptions, and the second one is not a convenience — it is a
            // bug fix. `hello` IS the start of the handshake. `ping` is pure
            // liveness and grants nothing, and DROPPING it broke pairing: the
            // phone pings every 5 s, gets no pong from a connection that has not
            // yet paired, and its watchdog concludes the link is dead and tears
            // it down — while the user is still reading the code off this
            // screen. Typing the code fast enough beat the watchdog, which is
            // why a wrong code could report "didn't match" while a correct one,
            // typed a minute later, hung forever.
            switch event {
            case .hello, .ping: break
            default:
                HostLog.write("RT1: dropped a message from an unauthenticated connection")
                return
            }
        }
        if case .ping = event {
            send(["t": "pong"])
            return
        }
        switch event {
        case .clipFilePush(let id, let name, let size):
            clipFile.begin(id: id, name: name, size: size) { send($0) }; return
        case .clipFileChunk(let id, let data):
            clipFile.chunk(id: id, b64: data) { send($0) }; return
        case .clipFileDone(let id):
            clipFile.done(id: id) { send($0) }; return
        case .clipFilePull(let id):
            clipFile.pull(id: id) { send($0) }; return
        default: break
        }
        if case let .hello(name, version) = event {
            clientHelloVersion = version
            clientName = name
            lastEvent = "connected: \(name)"
            HostLog.write("connected: \(name)")

            // An RT1 phone puts its device tag, nonce and ephemeral key in the
            // hello. `helloRT1` is stashed by drainLines because InputEvent has
            // no room for them — parsing them here keeps one hello on the wire
            // instead of adding a round trip.
            if let rt = helloRT1 {
                helloRT1 = nil
                let (fields, failure) = rt1.beginSession(tagB64: rt.tag,
                                                         noncePhoneB64: rt.nonce,
                                                         epkPhoneB64: rt.epk)
                if let failure {
                    // Unknown device: answer honestly and let the phone offer to
                    // pair. Do NOT fall back to an open connection.
                    send(failure, from: connection)
                    return
                }
                var hi: [String: Any] = ["t": "hi", "v": Self.protocolVersion,
                                         "name": Host.current().localizedName ?? "Mac",
                                         "os": "mac", "cast": 1, "browser": 1, "audio": 1,
                                         "direct": CastWebRTC.isAvailable ? 1 : 0]
                fields.forEach { hi[$0.key] = $0.value }
                send(hi, from: connection)
                return
            }

            // No RT1 in the hello. Answer it anyway — an unanswered hello
            // leaves an older phone hanging on its legacy timer — but the
            // connection stays UNAUTHENTICATED, so the guard above drops
            // everything that follows. `rt` and `hid` ride along so an
            // RT1-capable phone that simply has no pairing yet can see what to
            // do next instead of guessing.
            rt1.markLegacy()
            // Surface it HERE, on the computer, because the phone cannot be
            // told: a phone old enough to skip RT1 is old enough to ignore any
            // field explaining why nothing works. Without this line the user
            // sees a phone that says "connected" and does nothing, on both
            // screens, with no explanation on either.
            legacyPhoneName = name
            HostLog.write("RT1: \(name) connected without RT1 — refusing input until it pairs")
            refreshAccessibility(); refreshScreenRecording()
            HostLog.write("perms probe: ax=\(accessibilityTrusted) sr=\(screenRecordingTrusted) axRaw=\(AXIsProcessTrusted()) cgPreflight=\(CGPreflightPostEventAccess())")
            send(["t": "hi", "v": Self.protocolVersion,
                  "rt": RT1.version, "hid": Identity.shared.hostID,
                  "ax": accessibilityTrusted ? 1 : 0, "sr": screenRecordingTrusted ? 1 : 0,
                  "name": Host.current().localizedName ?? "Mac",
                  // `direct` advertises Cast DIRECT (§6.5) only when the WebRTC
                  // sidecar is actually bundled, so a phone never offers it to a
                  // host that would just answer cast.err.
                  // `audio` advertises COMPUTER-AUDIO streaming (the "Screen +
                  // audio" / "Audio only" modes). macOS has the ScreenCaptureKit
                  // tap; the Windows host has no capture at all, so it omits the
                  // flag and the phone hides those rows instead of offering a
                  // mode that would be silent.
                  // `os` lets the phone reason about host capabilities that
                  // predate an explicit flag (a host older than `audio` is a Mac
                  // iff os says so — see the client's audio-capability rule).
                  "os": "mac",
                  "cast": 1, "browser": 1, "audio": 1,
                  "direct": CastWebRTC.isAvailable ? 1 : 0])
            // Nothing else. The permissions reply says which trusts this Mac has
            // granted, and the cast snapshot names the TV in the room — both are
            // things about the machine, sent unprompted, to a peer that has
            // proved nothing. They now happen at `rt.conf`, once it has.
            return
        }
        if case let .permFix(id) = event {
            fixPermission(id)
            return
        }
        // Clipboard bridge — answered here via NSPasteboard (already on the
        // main queue: the connection runs on .main), not routed through the
        // Injector, and not gated on Accessibility (the pasteboard needs no
        // event-injection trust). It IS gated on a completed v2 hello on this
        // same connection: the pasteboard routinely holds passwords, and a
        // raw socket that never introduced itself must not be able to read it
        // out (or poison it) with one line of JSON. Contents are never logged
        // or displayed — lastEvent/HostLog only ever say "clipboard".
        switch event {
        case .clipSet, .clipGet:
            guard clientHelloVersion >= 2 else {
                lastEvent = "clipboard ignored (no v2 hello)"
                HostLog.write("clipboard ignored: no v2 hello on this connection")
                return
            }
        case .vitalsSub, .vitalsUnsub:
            // Same gate as clip.*: a raw socket that never introduced itself
            // doesn't get a telemetry stream of this Mac.
            guard clientHelloVersion >= 2 else {
                lastEvent = "vitals ignored (no v2 hello)"
                HostLog.write("vitals ignored: no v2 hello on this connection")
                return
            }
        case .openApp:
            // Same gate as clip.*: a raw socket that never introduced itself
            // must not be able to launch apps on this Mac.
            guard clientHelloVersion >= 2 else {
                lastEvent = "open ignored (no v2 hello)"
                HostLog.write("open ignored: no v2 hello on this connection")
                return
            }
        case .proxArm, .proxDisarm:
            // Same gate as clip.*: a raw socket that never introduced itself
            // must not be able to arm a screen-lock trigger on this Mac.
            guard clientHelloVersion >= 2 else {
                lastEvent = "proximity ignored (no v2 hello)"
                HostLog.write("proximity ignored: no v2 hello on this connection")
                return
            }
        case .ovlMode, .ovlMove, .ovlInk, .ovlClear, .ovlCursor:
            // Same gate as clip.*: a raw socket that never introduced itself
            // doesn't get to draw a full-screen overlay on this Mac.
            guard clientHelloVersion >= 2 else {
                lastEvent = "overlay ignored (no v2 hello)"
                HostLog.write("overlay ignored: no v2 hello on this connection")
                return
            }
        case .tvSub, .tvUnsub, .tvFollow, .tvZoom, .tvPoint:
            // Same gate as clip.*: a raw socket that never introduced itself
            // doesn't get to read this Mac's SCREEN. (Screen Recording TCC is the
            // OS-level gate; this is the protocol-level one.)
            guard clientHelloVersion >= 2 else {
                lastEvent = "tv ignored (no v2 hello)"
                HostLog.write("tv ignored: no v2 hello on this connection")
                return
            }
        case .edgeArm, .edgeDisarm, .edgeRelease, .edgeEnter:
            guard clientHelloVersion >= 2 else {
                lastEvent = "edge ignored (no v2 hello)"
                HostLog.write("edge ignored: no v2 hello on this connection")
                return
            }
        case .audioSub, .audioUnsub:
            // Same gate: a raw socket that never introduced itself doesn't get to
            // tap this Mac's AUDIO. (Screen Recording TCC is the OS-level gate.)
            guard clientHelloVersion >= 2 else {
                lastEvent = "audio ignored (no v2 hello)"
                HostLog.write("audio ignored: no v2 hello on this connection")
                return
            }
        case .castScanSub, .castScanUnsub, .castReach, .castStart, .castStop,
             .castPin, .castQuality, .castVolume, .castDisplay, .castSig:
            // Same gate as clip.*: a raw socket that never introduced itself
            // doesn't get to enumerate this LAN's TVs or put this Mac's screen
            // on one. (Hello-gating is a version handshake, not a security
            // boundary — CASTING.md §14.5 states the trust model honestly.)
            guard clientHelloVersion >= 2 else {
                lastEvent = "cast ignored (no v2 hello)"
                HostLog.write("cast ignored: no v2 hello on this connection")
                return
            }
        default:
            break
        }
        switch event {
        case .clipSet(let s):
            lastEvent = "clipboard received"
            HostLog.write("clipboard set")
            guard s.utf8.count <= Self.clipboardByteCap else { return }  // phone enforces too; belt and braces
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            return
        case .clipGet(let id):
            lastEvent = "clipboard requested"
            HostLog.write("clipboard get")
            // Echo the phone's correlation id so a slow reply can't resolve a
            // newer fetch with this (older) request's snapshot.
            var reply: [String: Any] = ["t": "clip"]
            if let id { reply["id"] = id }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if text.isEmpty {
                reply["err"] = "empty"
            } else if text.utf8.count > Self.clipboardByteCap {
                reply["err"] = "toolarge"
            } else {
                reply["s"] = text
            }
            send(reply)
            return
        case .vitalsSub:
            // Never log now-playing content — lastEvent/HostLog say "vitals".
            lastEvent = "vitals"
            HostLog.write("vitals subscribed")
            startVitals()
            return
        case .vitalsUnsub:
            lastEvent = "vitals"
            HostLog.write("vitals unsubscribed")
            stopVitals()
            return
        case .tvSub(let w, let h, let zoom, let follow):
            lastEvent = "tv on"
            // The size is worth logging: the lens is cut to THIS aspect
            // (Capture.regionAround), so "why is there a black bar" and "why is
            // the picture soft" are both answered by this one line.
            HostLog.write("tv subscribed \(w)x\(h) z=\(zoom) follow=\(follow)")
            startTV(w: w, h: h, zoom: zoom, follow: follow)
            return
        case .tvUnsub:
            lastEvent = "tv off"
            HostLog.write("tv unsubscribed")
            stopTV()
            return
        case .tvFollow(let mode):
            // Live follow-mode change — no restart; ~no log (it's a quick toggle).
            capture.setFollow(TVFollow(wire: mode))
            return
        case .tvZoom(let z):
            capture.setZoom(z)   // live magnification — no log (slider spam)
            return
        case .edgeArm(let sides):
            edge.arm(sides)
            return
        case .edgeDisarm:
            edge.disarm()
            return
        case .edgeRelease(let to, let y):
            edge.park(to: to, y: y)   // leaving this Mac — park cursor + disarm
            return
        case .edgeEnter(let from, let y):
            edge.warp(from: from, y: y)   // arriving on this Mac — warp cursor in
            return
        case .tvPan(let dx, let dy):
            capture.setPan(dx: dx, dy: dy)   // manual steer — no log (drag spam)
            return
        case .tvPoint(let x, let y, let seq):
            // INLINE, on .main, in wire order — deliberately not hopped onto a queue.
            // drainLines applies lines synchronously, and the `mc` that follows a tap
            // reads the live cursor, so the warp has to have happened by the time it
            // runs or the click lands where the pointer used to be.
            //
            // Sits BEFORE the Accessibility guard on purpose: the warp is
            // CGWarpMouseCursorPosition, which needs no AX grant. Pointing therefore
            // works on a Mac that has only granted Screen Recording; only the click
            // that follows is refused, which is the honest failure.
            capture.pointAt(x: x, y: y, seq: seq)   // no log (drag spam)
            return
        case .audioSub:
            lastEvent = "audio on"
            HostLog.write("audio subscribed")
            startAudio()
            return
        case .audioUnsub:
            lastEvent = "audio off"
            HostLog.write("audio unsubscribed")
            stopAudio()
            return
        case .castScanSub:
            lastEvent = "cast scan on"
            HostLog.write("cast scan subscribed")
            castScanSubscriber = connection
            castDiscovery.start()
            // First FULL snapshot answers the sub immediately (§8.1: an empty
            // room answers with an empty list, never silence).
            if let subscriber = castScanSubscriber {
                send(["t": "cast.targets", "items": castDiscovery.snapshot()], from: subscriber)
            }
            return
        case .castScanUnsub:
            lastEvent = "cast scan off"
            HostLog.write("cast scan unsubscribed")
            stopCastScan()
            return
        case .castReach(let addr, let port, let rid):
            // Never log the address — the log says only "cast reach".
            lastEvent = "cast reach"
            HostLog.write("cast reach")
            let requester = connection
            CastReach.probe(addr: addr, port: port) { [weak self] ok in
                self?.send(["t": "cast.reach.res", "rid": rid, "ok": ok], from: requester)
            }
            return
        case .castStart(let rid, let targetId, let targetType, let addr, let port,
                        let audio, let quality, _, let force):
            // The menu bar shows the sink name once the session owns it; the
            // log stays content-free ("cast start", codes/states only).
            lastEvent = "cast start"
            HostLog.write("cast start requested")
            startCast(rid: rid, targetId: targetId, targetType: targetType,
                      addr: addr, port: port, audio: audio, quality: quality, force: force)
            return
        case .castStop(let sid):
            guard sid == castSession.sid else { return }   // stale sid never stops a newer session
            lastEvent = "cast stop"
            HostLog.write("cast stop requested")
            castSession.stop()
            return
        case .castPin(let sid, let code):
            // The session logs "cast pin typed"; the code itself never appears
            // in logs or UI.
            lastEvent = "cast pin"
            castSession.pin(code, sid: sid)
            return
        case .castSig(let sid, let token, let kind, let data):
            // Cast DIRECT signaling relay (§6.6): forward the receiver's answer/ICE
            // to the sidecar, but ONLY for the live session and a matching token
            // (§14.2). The log stays content-free — never the SDP/ICE body (§14.6).
            guard sid == castSession.sid, let expected = castToken,
                  CastHTTPServer.constantTimeEqual(token, expected),
                  kind == "answer" || kind == "ice",
                  let webrtc = castWebRTC else { return }
            webrtc.applyRemote(kind: kind, data: data)
            return
        case .castVolume(_, let level):
            // The phone's TV-volume buttons. This was an accepted NO-OP — true
            // when the only path was a native OS mirror the OS owned, but on our
            // own WebRTC session it meant the buttons did nothing at all. Drive
            // the sink's real volume over CASTv2.
            castWebRTC?.setVolume(level)
            return
        case .castQuality, .castDisplay:
            // NATIVE slice: the OS owns the mirror — nothing to adjust yet.
            // Accepted no-ops so newer phones never error against this host.
            return
        case .openApp(let name):
            // Validate trimmed 1–64 chars, then spawn. The app name shows in the
            // menu bar's in-memory last-event line, but only a content-free
            // marker goes to HostLog: the log file is world-readable (/tmp) and
            // an app name can occasionally be revealing (a niche medical/finance
            // app the user launched), so it stays out of the persisted file —
            // matching how clipboard/now-playing/token are kept out of the log.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 64 else { return }
            lastEvent = "open \(trimmed)"
            HostLog.write("open app")
            openApplication(trimmed)
            return
        case .proxArm(let token, let near, let grace):
            // Never log the token (it's the per-session secret the arming is
            // bound to) — the log/UI say only "proximity armed".
            lastEvent = "proximity armed"
            HostLog.write("proximity armed")
            proximityArmed = true
            // Pin prox frames to THIS connection (v2-gated above). A re-arm from
            // a reconnecting phone re-pins to the new socket.
            proximityArmer = connection
            // Do NOT force the phase here: an identical re-arm (same token+config)
            // is a no-op in the monitor that KEEPS its live phase (e.g. .locked),
            // and the monitor's onState is the single source of phase. Forcing
            // .searching would flap the menu on every reconnect re-arm.
            proximity.start(token: token,
                            config: ProximityConfig(nearDbm: near,
                                                    graceSeconds: Double(grace)))
            return
        case .proxDisarm:
            lastEvent = "proximity off"
            HostLog.write("proximity disarmed")
            proximityArmed = false
            proximityPhase = nil
            proximityArmer = nil
            lastLoggedProximityPhase = nil
            proximity.stop()
            return
        case .ovlMode(let m, let rf, let dim, let col):
            lastEvent = "overlay \(m)"
            HostLog.write("overlay \(m)")
            overlay.setMode(m, rf: rf, dim: dim, col: col)
            return
        case .ovlTimer(let on, let secs, let warn):
            lastEvent = on ? "audience timer" : "audience timer off"
            HostLog.write("overlay timer \(on ? "on" : "off")")
            overlay.setTimer(on: on, secs: secs, warn: warn)
            return
        case .ovlMove(let x, let y):
            // ~60/s — deliberately no lastEvent/HostLog write (it would thrash
            // the menu line and flood the /tmp log); the mode change already
            // logged "overlay <mode>".
            overlay.move(x: x, y: y)
            return
        case .ovlInk(let p, let x, let y):
            overlay.ink(phase: p, x: x, y: y)   // ~60/s — same, no log
            return
        case .ovlClear:
            lastEvent = "overlay clear"
            HostLog.write("overlay clear")
            overlay.clear()
            return
        case .ovlCursor(let x, let y):
            overlay.cursor(x: x, y: y)   // ~60/s — no log; moves the real cursor
            return
        default:
            break
        }
        let desc = describe(event)
        lastEvent = desc
        HostLog.write(desc)
        guard accessibilityTrusted else { return }
        // A trackpad move while the TV lens is manually panned → warp the cursor into
        // the framed region and follow it (you panned to act on what's there).
        if case .mouseMove = event, capture.isManualFollow {
            capture.exitManualToCursor()
        }
        injector.handle(event)
    }

    private func describe(_ e: InputEvent) -> String {
        switch e {
        case .hello(let n, _): return "hello \(n)"
        case .ping: return "ping"
        case .clipFilePush(_, let n, let sz): return "clip.file.push \(n) \(sz)B"
        case .clipFileChunk: return "clip.file.chunk"
        case .clipFileDone: return "clip.file.done"
        case .clipFilePull: return "clip.file.pull"
        case .ovlTimer(let on, _, _): return "ovl.timer \(on ? "on" : "off")"
        case .keyChar(let c, let m): return "key '\(c)' mods \(m)"
        case .keyNamed(let n, let m): return "key \(n) mods \(m)"
        case .text(let s, let d): return "text del \(d) +\(s.count)"
        case .modifier(let b, let down): return "mod \(b) \(down ? "down" : "up")"
        case .zoom(let d): return "zoom \(d)"
        case .mouseMove(let dx, let dy, _): return "move \(dx),\(dy)"
        case .mouseButton(let b, let d, _): return "btn \(b) \(d ? "down" : "up")"
        case .mouseClick(let b, _): return "click \(b)"
        case .scroll(_, let dy, _): return "scroll \(dy)"
        case .consumer(let u): return "media \(u)"
        // Handled before describe is reached; kept for exhaustiveness. Never
        // the text itself — clipboard contents stay out of logs and UI.
        case .clipSet: return "clipboard"
        case .clipGet: return "clipboard"
        // Same: handled in apply; now-playing content stays out of logs/UI.
        case .vitalsSub, .vitalsUnsub: return "vitals"
        // Handled in apply (returns before describe). The menu bar shows the
        // name; the log gets a content-free "open app" marker — see apply().
        case .openApp(let n): return "open \(n)"
        // Handled in apply; kept for exhaustiveness. Never the token — the
        // arming's per-session secret stays out of logs/UI.
        case .proxArm: return "proximity armed"
        case .proxDisarm: return "proximity off"
        // Handled in apply (returns before describe). Move/ink are intentionally
        // not logged per-frame; kept here for exhaustiveness.
        case .ovlMode(let m, _, _, _): return "overlay \(m)"
        case .ovlMove: return "overlay move"
        case .ovlInk: return "overlay ink"
        case .ovlClear: return "overlay clear"
        case .ovlCursor: return "overlay cursor"
        // Handled in apply (returns before describe); kept for exhaustiveness.
        case .tvSub: return "tv on"
        case .tvUnsub: return "tv off"
        case .tvFollow: return "tv follow"
        case .tvZoom: return "tv zoom"
        case .tvPan: return "tv pan"
        case .tvPoint: return "tv point"
        // Handled in apply (returns before describe); kept for exhaustiveness.
        case .edgeArm: return "edge arm"
        case .edgeDisarm: return "edge disarm"
        case .edgeRelease: return "edge release"
        case .edgeEnter: return "edge enter"
        // Handled in apply (returns before describe); kept for exhaustiveness.
        case .audioSub: return "audio on"
        case .audioUnsub: return "audio off"
        // Handled in apply (returns before describe); kept for exhaustiveness.
        // Never a sink name, address, or PIN — cast logging is codes/states only.
        case .castScanSub: return "cast scan on"
        case .castScanUnsub: return "cast scan off"
        case .castReach: return "cast reach"
        case .castStart: return "cast start"
        case .castStop: return "cast stop"
        case .castPin: return "cast pin"
        case .castQuality: return "cast quality"
        case .castVolume: return "cast volume"
        case .castDisplay: return "cast display"
        case .castSig: return "cast sig"   // never the SDP/ICE body (§14.6)
        case .permFix: return "perm fix"
        }
    }

    // MARK: Screen casting (CASTING.md, slice 1)

    /// `cast.start` for this slice: NATIVE (AirPlay) only. Enforces the §10.1
    /// one-session rules, resolves the target against the host's own discovery
    /// cache (§4: the phone's addr/port are advisory), and answers within the
    /// 2 s contract — every path below replies synchronously.
    private func startCast(rid: String, targetId: String, targetType: String,
                           addr: String?, port: Int?, audio: Bool, quality: String, force: Bool) {
        let requester = connection
        if castSession.isActive {
            if !force {
                // A cast is already live (possibly started by another device — the
                // owner may even be gone). Answer `busy` — ALWAYS rid-bearing and
                // pinned to the requester, so the phone resolves its pending
                // cast.start instead of timing out. The phone compares `sid` to its
                // own session to decide "switch" (mine) vs "take over" (another
                // device), and re-sends with force:true to proceed.
                var msg: [String: Any] = ["t": "cast.err", "rid": rid, "code": "busy",
                                          "msg": "This computer's screen is already being cast."]
                if let sid = castSession.sid { msg["sid"] = sid }
                if let name = castSession.target?.name { msg["target"] = name }
                send(msg, from: requester)
                return
            }
            // Take over: tear the current cast down (finish() → state .idle, closes
            // the old browser server → its viewers get "Cast ended"), then start
            // fresh below.
            castSession.stop()
        }
        // BROWSER (Tier B0, §7.0): a virtual target — no discovery, no addr/port.
        // Branch BEFORE the airplay-only guard; the one-session busy/idempotent
        // rules above already covered "browser while another cast is live".
        if targetType == "browser" {
            startBrowserCast(rid: rid, audio: audio, quality: quality)
            return
        }
        // CAST DIRECT (§6.5 Tier 1): WebRTC to a Cast receiver. Needs the sink's
        // addr/port for the host's own connection; resolve from the discovery cache.
        if targetType == "cast" {
            // §4 "target identity authority": prefer OUR discovery record, but the
            // phone's addr/port are advisory-and-usable when we have none. Our
            // browse only runs while a client holds cast.scan.sub and takes
            // 20-30 s to resolve, so refusing a sink we simply haven't listed yet
            // told the user their computer and TV weren't on the same network —
            // untrue, and it made casting look broken.
            let cached = castDiscovery.target(withId: targetId)
            guard cached != nil || !(addr ?? "").isEmpty else {
                send(["t": "cast.err", "rid": rid, "code": "unreachable",
                      "msg": "Your computer can't see that TV right now — both need to be on the same Wi-Fi."],
                     from: requester)
                return
            }
            let t = CastSession.Target(id: cached?.id ?? targetId, name: cached?.name ?? "TV",
                                       type: cached?.type ?? targetType,
                                       addr: cached?.addr ?? addr, port: cached?.port ?? port)
            startDirectCast(rid: rid, target: t, audio: audio, quality: quality)
            return
        }
        guard targetType == "airplay" else {
            send(["t": "cast.err", "rid": rid, "code": "unsupported",
                  "msg": "This computer can't cast to that display."], from: requester)
            return
        }
        guard let cached = castDiscovery.target(withId: targetId) else {
            // NATIVE needs the sink's NAME (the AX script selects it by title)
            // and cast.start carries none — a sink this host has never seen is
            // one it can't reach.
            send(["t": "cast.err", "rid": rid, "code": "unreachable",
                  "msg": "Your computer can't see that TV right now — both need to be on the same Wi-Fi."],
                 from: requester)
            return
        }
        var target = CastSession.Target(id: cached.id, name: cached.name, type: cached.type,
                                        addr: cached.addr, port: cached.port)
        if target.addr == nil {
            target.addr = addr
            target.port = port
        }
        castSessionOwner = requester
        castSession.start(rid: rid, target: target, audio: audio, quality: quality)
    }

    /// The menu bar's "Casting to <TV> — Stop" — the only stop affordance that
    /// survives a dead phone (§9.2).
    func stopCast() {
        castSession.stop()
    }

    /// BROWSER cast start (§7.0, Tier B0). Preflight Screen Recording (else
    /// noperm) → pick a browser-reachable LAN address (§6.7, else unreachable) →
    /// mint token+code → bind the HTTP server → start the full-display capture →
    /// hand the state machine to CastSession which answers `cast.ready` with the
    /// URL/code the phone renders as a QR. Skips ALL airplay/discovery machinery.
    private func startBrowserCast(rid: String, audio: Bool, quality: String) {
        let requester = connection
        lastEvent = "cast start (browser)"
        HostLog.write("cast browser requested")   // content-free: no token/url/code
        // Free the fixed port from any prior session still in its 410 grace so the
        // new server rebinds 50809 (stable URL for browser history), not ephemeral.
        browserHTTPGracing?.forceClose()
        browserHTTPGracing = nil
        refreshScreenRecording()
        guard screenRecordingTrusted else {
            send(["t": "cast.err", "rid": rid, "code": "noperm",
                  "msg": "Screen Recording is off — turn it on for Remotype Host in System Settings, then try again."],
                 from: requester)
            return
        }
        guard let ip = LANInterface.pick() else {
            // §6.7: host only on Tailscale/VPN — no interface a browser can reach.
            send(["t": "cast.err", "rid": rid, "code": "unreachable",
                  "msg": "Your computer isn't on a local network a browser can reach — connect it to Wi-Fi/Ethernet."],
                 from: requester)
            return
        }
        let (token, code) = CastHTTPServer.newCredentials()
        let computer = Host.current().localizedName ?? "Mac"
        let html = BrowserReceiver.page(computer: computer, token: token, audio: audio)
        let server = CastHTTPServer(ip: ip, token: token, code: code, audioEnabled: audio, html: html)
        server.onViewersChanged = { [weak self] count in
            DispatchQueue.main.async { self?.castSession.setBrowserViewers(count) }
        }
        // Lazily capture computer audio only while a browser has "Enable sound" on
        // (the WebSocket is open) — no system-audio tap when nobody's listening.
        server.onAudioWanted = { [weak self, weak server] wanted in
            DispatchQueue.main.async { self?.setBrowserAudio(wanted, server: server) }
        }
        browserHTTP = server
        server.start { [weak self, weak server] port in
            DispatchQueue.main.async {
                guard let self, let server else { return }
                // A teardown (or a newer start) raced the async bind — discard.
                guard self.browserHTTP === server else { server.stop(); return }
                guard let port else {
                    self.browserHTTP = nil
                    self.send(["t": "cast.err", "rid": rid, "code": "unreachable",
                               "msg": "Your computer isn't on a local network a browser can reach — connect it to Wi-Fi/Ethernet."],
                              from: requester)
                    return
                }
                // The session must still be idle for startBrowser to adopt it — if
                // another cast (e.g. an AirPlay start) slipped in during the async
                // bind, don't strand a running capture + open HTTP server with no
                // session tracking it (startBrowser would silently no-op).
                guard self.castSession.state == .idle else { self.browserHTTP = nil; server.stop(); return }
                let url = "http://\(ip):\(port)/c/\(token)"
                self.startBrowserCapture(feeding: server)
                self.castSessionOwner = requester
                self.castSession.browserFPS = { [weak server] in server?.fps ?? 0 }
                self.castSession.onStopped = { [weak self] in self?.stopBrowserServe() }
                self.castSession.startBrowser(rid: rid, url: url, code: code, token: token,
                                              audio: audio, quality: quality)
            }
        }
    }

    /// CAST DIRECT start (§6.5 Tier 1). Preflight Screen Recording → build the
    /// H.264 encoder + WebRTC sidecar → relay the sidecar's offer/ICE to the phone
    /// over cast.sig → on ICE-connected, start the full-display raw capture feeding
    /// the encoder (+ stereo audio if wanted). Best-effort: a missing helper or a
    /// sink that can't do WebRTC surfaces a friendly cast.err.
    private func startDirectCast(rid: String, target: CastSession.Target, audio: Bool, quality: String,
                                 forceHLS: Bool = false) {
        let requester = connection
        lastEvent = "cast start (direct)"
        HostLog.write("cast direct requested\(forceHLS ? " (HLS fallback)" : "")")   // content-free
        refreshScreenRecording()
        guard screenRecordingTrusted else {
            send(["t": "cast.err", "rid": rid, "code": "noperm",
                  "msg": "Screen Recording is off — turn it on for Remotype Host in System Settings, then try again."],
                 from: requester)
            return
        }
        let useHLS = forceHLS || (CastConfig.appID == "CC1AD845")
        // Encode at the SOURCE DISPLAY'S aspect ratio, not a fixed 16:9 box.
        // SCK's scalesToFit letterboxed a 16:10 Mac into 1280x720, baking black
        // bars into the video — and the TV then letterboxed that AGAIN, so the
        // picture never filled the panel and wasted pixels on bars.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let srcAR = bounds.width / max(bounds.height, 1)
        // The §12 cast-quality preference finally does something. It was plumbed
        // from both phones all the way to here and then ignored, so every cast got
        // the same conservative rung.
        //
        //   high_quality -> the display's NATIVE backing resolution (Retina, so
        //                   3600x2338 on this Mac — more pixels than 4K UHD),
        //                   capped at a 3840 long edge. Needs a 4K-class sink:
        //                   a first-gen Chromecast decodes 1080p only.
        //   low_latency  -> smaller frame, fewer bits, quickest to settle.
        //   auto         -> 1080p-class, the sane default.
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let nativeLong = Double(max(mode?.pixelWidth ?? 1920, mode?.pixelHeight ?? 1200))
        let longEdgeCap: Double
        switch quality {
        case "high_quality": longEdgeCap = min(3840, max(1920, nativeLong))
        case "low_latency":  longEdgeCap = 1280
        default:             longEdgeCap = 1920
        }
        // Fit the cap to the display's own aspect; H.264 wants even dimensions.
        // high_quality means MAX: take the panel's native pixels as-is (only
        // clamped to a 4K-class ceiling) instead of squeezing them under a 16:10
        // height rule that would throw away ~8% for no reason.
        var ew: Double
        var eh: Double
        if quality == "high_quality" {
            // Clamp PRESERVING ASPECT. Taking min() on each axis independently
            // squashed any panel wider than 16:10 into the 3840x2400 box: a
            // 5120x2160 ultrawide came out 3840x2160 — 21:9 content stretched
            // into a 16:9 frame on the TV. Scale by whichever axis binds first.
            ew = Double(mode?.pixelWidth ?? 1920)
            eh = Double(mode?.pixelHeight ?? 1200)
            let fit = min(1.0, min(3840 / max(ew, 1), 2400 / max(eh, 1)))
            ew = (ew * fit).rounded(.down)
            eh = (eh * fit).rounded(.down)
        } else {
            ew = longEdgeCap
            eh = (ew / srcAR).rounded()
            let heightCap = longEdgeCap * 0.625   // keeps a 16:10 source inside the cap
            if eh > heightCap { eh = heightCap.rounded(); ew = (eh * srcAR).rounded() }
        }
        let fps = 30
        // Hardware coded-size ceiling: TV H.264 decoders conform to 4096x2304
        // max DIMENSIONS on top of the Level 5.1 rate below. 2314 rows failed to
        // render where 2250 worked — ten pixels over this cap is still a silent
        // black screen. Clamp preserving aspect.
        if eh > 2304 { ew = (ew * 2304 / eh).rounded(.down); eh = 2304 }
        if ew > 4096 { eh = (eh * 4096 / ew).rounded(.down); ew = 4096 }
        // THE 4K RENDERING CLIFF. H.264 Level 5.1 — the ceiling for most TV
        // decoders, chosen so 3840x2160@30 (972,000 MB/s) fits — allows 983,040
        // macroblocks/second. This Mac's native 3600x2338@30 is 992,250: ONE
        // percent over, and the decoder rejects the stream in total silence —
        // ICE connects, packets flow, zero PLI, and the screen never leaves the
        // splash. (3464x2250, the sizing this replaced, fit at 917,910 — which
        // is why that version rendered and "true native" never did.)
        // Scale down to the largest size the decoder will actually accept.
        let mbBudget = Double(983_040 / fps) * 0.99   // 1% safety margin
        let mbs = ((ew + 15) / 16).rounded(.down) * ((eh + 15) / 16).rounded(.down)
        if mbs > mbBudget {
            let scale = (mbBudget / mbs).squareRoot()
            ew = (ew * scale).rounded(.down)
            eh = (eh * scale).rounded(.down)
        }
        let w = max(2, Int(ew) & ~1)
        let h = max(2, Int(eh) & ~1)
        // `legacy` pins Constrained Baseline + 1 s IDR for a frozen-firmware
        // Chromecast on the HLS path. The WebRTC receivers decode High profile
        // fine, and High (CABAC) is materially sharper at the same bitrate.
        let legacy = useHLS
        // Screen content is mostly static with sharp text, which is exactly what
        // starves at 2.5 Mbps. This is a CEILING: the §6.4 BWE ladder settles
        // wherever the link actually allows.
        let ceilBitrate: Int
        if useHLS {
            ceilBitrate = 4_000_000
        } else {
            switch quality {
            // A near-4K desktop full of text needs a LOT of bits to stay crisp.
            // Still only a ceiling — BWE settles wherever the link actually is.
            case "high_quality": ceilBitrate = 40_000_000
            case "low_latency":  ceilBitrate = 6_000_000
            default:             ceilBitrate = 12_000_000
            }
        }
        // With our custom receiver App ID set (CastConfig.appID = 93EC8A58) the host
        // takes the WebRTC (Tier 1) path — sub-second, host-driven. `useHLS` is only
        // true if the ID is reverted to Google's Default Media Receiver (CC1AD845),
        // which stays the automatic §6.5 fallback (mux → serve → LOAD) when WebRTC
        // can't connect.
        // WebRTC by default; HLS when the ID is the Default Media Receiver OR when a
        // prior WebRTC attempt fell back (forceHLS) — e.g. the custom receiver isn't
        // published / hasn't propagated to this Cast device yet.
        // START well below the ceiling and let the BWE ladder climb. Opening at
        // 40 Mbps meant the very first IDR of a near-4K frame was enormous, and on
        // a busy Wi-Fi it shredded before the decoder ever assembled a keyframe —
        // the receiver sat on its splash forever while everything upstream looked
        // healthy. Intermittent by nature: it worked on a quiet link and failed on
        // a busy one, which is exactly how it behaved.
        let startBitrate = min(ceilBitrate, 8_000_000)
        HostLog.write("cast encode \(w)x\(h)@\(fps) \(legacy ? "baseline" : "high") start \(startBitrate / 1_000_000) ceil \(ceilBitrate / 1_000_000) Mbps [\(quality)]")
        let encoder = CastEncoder(width: w, height: h, fps: fps, bitrate: startBitrate, legacy: legacy)
        guard encoder.start() else {
            send(["t": "cast.err", "rid": rid, "code": "unsupported",
                  "msg": "This computer couldn't start the video encoder for casting."], from: requester)
            return
        }
        let (token, _) = CastHTTPServer.newCredentials()
        let computer = Host.current().localizedName ?? "Mac"
        let webrtc = CastWebRTC()
        encoder.onAccessUnit = { [weak webrtc] data, pts in webrtc?.writeVideo(data, ptsUS: pts) }
        webrtc.onSignal = { [weak self] kind, sig in
            DispatchQueue.main.async {
                guard let self, let sid = self.castSession.sid, let owner = self.castSessionOwner else { return }
                self.send(["t": "cast.sig", "sid": sid, "token": token, "kind": kind, "data": sig], from: owner)
            }
        }
        webrtc.onBitrate = { [weak self] bps in
            DispatchQueue.main.async {
                // Clamp the GCC estimate to a sane band and drive the encoder (§6.4).
                let clamped = min(max(bps, 1_500_000), ceilBitrate)
                self?.castEncoder?.setBitrate(clamped)
            }
        }
        webrtc.onConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.castSession.directConnected()
                self.castCapture.start(w: w, h: h, zoom: 1.0, follow: .full,
                                       onSample: { [weak self] sb in self?.castEncoder?.encode(sb) })
                if audio {
                    if useHLS {
                        // Tier-3 HLS: real computer audio → AAC-LC ADTS → the muxer's
                        // audio slots (kind 3). Replaces the silent placeholder track.
                        self.castAudioAAC.start { [weak self] adts in self?.castWebRTC?.writeAudioAAC(adts) }
                        self.castAudio.start { [weak self] pcm in self?.castAudioAAC.feed(pcm) }
                    } else {   // WebRTC path: PCM → Opus in the sidecar
                        self.castAudio.start { [weak self] pcm in self?.castWebRTC?.writeAudio(pcm, ptsUS: 0) }
                    }
                }
            }
        }
        webrtc.onFailed = { [weak self] in
            DispatchQueue.main.async {
                // Sidecar died / peer failed → stop the session (best-effort degrade).
                guard let self, self.castSession.kind == .cast, self.castSession.isActive else { return }
                self.castSession.stop()
            }
        }
        webrtc.onReachFail = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.castSession.kind == .cast, self.castSession.isActive else { return }
                // "launch" = the sink was reachable but the WebRTC custom receiver
                // wouldn't start (LAUNCH_ERROR NOT_FOUND: the App ID isn't published,
                // hasn't propagated, or this device isn't a registered test device);
                // "connect" = truly unreachable.
                //
                // The §6.5 cascade says HLS is the automatic fallback when WebRTC
                // can't connect. Take it: tear the failed attempt down and restart
                // on Tier 3 (Default Media Receiver + live HLS), which needs no
                // custom receiver registration. The user sees a slightly longer
                // start instead of a dead end. Only once per attempt — a Tier-3
                // failure is terminal and reports honestly.
                // "noanswer" = the receiver launched but never completed the WebRTC
                // handshake. Same remedy as a failed launch: fall back to Tier 3.
                // "noplay": connected but the decoder never produced a frame —
                // the stream itself was rejected. Retry DIRECT one rung down
                // before considering HLS; auto's Level-4.x-class frame is decodable
                // on anything that can run the receiver at all.
                if reason == "noplay", !forceHLS, quality != "auto" {
                    HostLog.write("cast: connected but never rendered at [\(quality)] — retrying at [auto]")
                    self.castSession.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.startDirectCast(rid: rid, target: target, audio: audio, quality: "auto")
                    }
                    return
                }
                if reason == "launch" || reason == "noanswer" || reason == "noplay", !forceHLS {
                    HostLog.write("cast: custom receiver wouldn't launch — falling back to HLS")
                    self.lastEvent = "cast fallback (HLS)"
                    self.castSession.stop()
                    // Let the sink settle after the refused LAUNCH before re-LAUNCHing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self else { return }
                        self.startDirectCast(rid: rid, target: target, audio: audio,
                                             quality: quality, forceHLS: true)
                    }
                    return
                }
                if let owner = self.castSessionOwner, let sid = self.castSession.sid {
                    let msg = (reason == "launch" || reason == "noanswer")
                        ? "That TV couldn't start the Remotype receiver yet — if you just registered it, give it a few minutes and reboot the TV, then try again."
                        : "This computer can't reach that TV — make sure the TV and this computer are on the same Wi-Fi (not a guest network or VPN)."
                    self.send(["t": "cast.err", "sid": sid, "code": "host_unreachable", "msg": msg], from: owner)
                }
                self.castSession.stop()
            }
        }
        // Host-driven CASTv2 (§6.6): the sidecar LAUNCHes the receiver on the sink
        // and relays signaling (WebRTC) — or muxes + LOADs live HLS (Tier 3) — over
        // its own connection; no phone Cast SDK needed.
        // On the HLS path (default receiver or a WebRTC fallback), LAUNCH CC1AD845 —
        // NOT the custom App ID (which is exactly what failed to launch).
        guard webrtc.start(token: token, computer: computer, audio: audio, legacy: legacy,
                           fps: fps, castHost: target.addr, castPort: target.port,
                           appID: useHLS ? "CC1AD845" : CastConfig.appID, hls: useHLS) else {
            encoder.stop()
            send(["t": "cast.err", "rid": rid, "code": "unsupported",
                  "msg": "Casting to this kind of device isn't available on this computer yet."], from: requester)
            return
        }
        castEncoder = encoder
        castWebRTC = webrtc
        castToken = token
        castSessionOwner = requester
        castSession.onStopped = { [weak self] in self?.stopDirectServe() }
        castSession.startDirect(rid: rid, target: target, token: token, audio: audio, quality: quality)
    }

    /// The cast owner (phone) link dropped. The session deliberately survives a
    /// brief blip — a phone that reconnects re-pins the owner and cancels this — but
    /// if none comes back within the grace, auto-stop so the sink isn't left casting
    /// forever with no way to control it (the "stuck Chromecast, can't stop" bug).
    private func armCastOwnerGrace() {
        castOwnerGraceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.castSession.isActive, self.connection == nil else { return }
            HostLog.write("cast owner gone → auto-stop (freeing the sink)")
            self.castSession.stop()
        }
        castOwnerGraceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: item)
    }

    /// Teardown of the CAST DIRECT resources (§10.6). Wired to castSession.onStopped
    /// so it fires on cast.stop, menu Stop, take-over, sidecar failure, and quit.
    private func stopDirectServe() {
        castCapture.stop()
        castAudio.stop()
        castAudioAAC.stop()
        castEncoder?.stop()
        castEncoder = nil
        castWebRTC?.stop()
        castWebRTC = nil
        castToken = nil
    }

    /// Start the SECOND capture in `.full` mode at native/capped (≤1440p) res —
    /// NOT the small magnified TV lens — feeding every LAN browser via the server.
    private func startBrowserCapture(feeding server: CastHTTPServer) {
        let (w, h) = Self.browserCaptureSize()
        browserCapture.start(w: w, h: h, zoom: 1.0, follow: .full) { [weak server] jpeg in
            server?.broadcast(jpeg)   // hops onto the server's own queue
        }
    }

    /// Full-display output size: native pixels of the main display, capped to
    /// ≤ 2560×1440 (preserving aspect), even dimensions.
    /// Start/stop the computer-audio tap feeding the browser (lazy — driven by
    /// `onAudioWanted`: the first "Enable sound" starts it, the last mute/leave
    /// stops it). PCM is 48 kHz mono Int16, broadcast to the audio WebSockets.
    private func setBrowserAudio(_ wanted: Bool, server: CastHTTPServer?) {
        guard let server, browserHTTP === server else { return }
        if wanted {
            browserAudio.start { [weak server] pcm in server?.broadcastAudio(pcm) }
        } else {
            browserAudio.stop()
        }
    }

    private static func browserCaptureSize() -> (Int, Int) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        var pw = Double(bounds.width) * scale
        var ph = Double(bounds.height) * scale
        let s = min(2560.0 / max(pw, 1), 1440.0 / max(ph, 1), 1.0)
        pw *= s; ph *= s
        return (max(2, Int(pw.rounded()) & ~1), max(2, Int(ph.rounded()) & ~1))
    }

    /// Teardown of the browser SERVE resources (§10.6): stop the full-display
    /// capture, close the server + cancel viewers, invalidate the token (410
    /// grace). Wired to castSession.onStopped, so it fires on cast.stop, the
    /// menu-bar Stop, and quit. Safe to call when already stopped (no-op).
    private func stopBrowserServe() {
        browserCapture.stop()
        browserAudio.stop()
        // Hand the server to its 410 grace, but keep a handle so the next cast can
        // reclaim the fixed port instantly (§ fixed-port reuse) instead of falling
        // back to an ephemeral one.
        browserHTTPGracing?.forceClose()
        browserHTTPGracing = browserHTTP
        browserHTTP = nil
        browserHTTPGracing?.stop()
        castSession.browserFPS = nil
    }

    /// Called on cast.scan.unsub and on EVERY connection teardown path — the
    /// browse must never outlive its subscriber. The discovery CACHE survives
    /// (a cast.start racing a picker close still resolves); only the browsing
    /// stops. The session is handled separately and survives (see accept()).
    private func stopCastScan() {
        castDiscovery.stop()
        castScanSubscriber = nil
    }

    // MARK: Open app (Macro deck, )

    /// Launch an app by name. Always `/usr/bin/open` with an ARGUMENT ARRAY
    /// (`["-a", name]`) — NEVER a shell, NEVER string interpolation into a
    /// command line, so quoting/metacharacters in the name can only ever be
    /// part of the literal app name. The reply contract is failure-only:
    /// a spawn error or non-zero exit answers
    /// `{"t":"openresult","ok":false,"app":name}`; success sends nothing.
    /// `Process.run()` returns immediately and the termination handler fires
    /// on its own thread — `send` hops to .main itself — so the connection
    /// queue is never blocked while Launch Services resolves the name.
    private func openApplication(_ name: String) {
        let requester = connection   // pin the (possible) reply to this client
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", name]
        proc.terminationHandler = { [weak self] p in
            guard p.terminationStatus != 0 else { return }
            self?.send(["t": "openresult", "ok": false, "app": name], from: requester)
        }
        do {
            try proc.run()
        } catch {
            send(["t": "openresult", "ok": false, "app": name], from: requester)
        }
    }

    // MARK: Vitals stream

    /// Start (or restart — a duplicate sub is idempotent) the 1.5 s vitals
    /// timer on .main, the queue everything else in this file runs on. The
    /// first `sample()` seeds the CPU tick baseline and kicks off the async
    /// now-playing fetch without sending, so the first frame at +1.5 s
    /// carries a real CPU delta.
    private func startVitals() {
        stopVitals()
        // Capture the subscribing connection: accept() stops the timer when a
        // new client replaces this one, but a tick already enqueued via
        // send()'s async hop would otherwise resolve `self.connection` to the
        // replacement and deliver one frame before its hello. Pinning each
        // frame to the subscriber closes that one-frame hole in the v2 gate.
        guard let subscriber = connection else { return }
        _ = vitals.sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self, weak subscriber] in
            guard let self, let subscriber else { return }
            let s = self.vitals.sample()
            var msg: [String: Any] = ["t": "vitals", "cpu": s.cpu, "ram": s.ram, "vol": s.vol]
            if let np = s.np { msg["np"] = np }
            self.send(msg, from: subscriber)   // silent no-op if the connection just went away
        }
        timer.resume()
        vitalsTimer = timer
    }

    /// Called on vitals.unsub and on EVERY connection teardown path —
    /// replacement in accept(), .failed/.cancelled, and deinit. The timer
    /// must never outlive the subscriber.
    private func stopVitals() {
        vitalsTimer?.cancel()
        vitalsTimer = nil
    }

    // MARK: TV mode

    /// Start the magnified screen feed for the subscribing connection. Preflights
    /// the Screen Recording grant — if it's missing, the phone gets `tv.err
    /// noperm` (and shows a "grant it on the Mac" empty state) rather than a
    /// frozen blank. Each frame is built + base64'd on the capture's BACKGROUND
    /// queue (CaptureController.onFrame) and shipped via sendLine, pinned to the
    /// subscriber — so .main only writes bytes, never encodes a frame.
    private func startTV(w: Int, h: Int, zoom: Double, follow: String) {
        stopTV()
        guard let subscriber = connection else { return }
        refreshScreenRecording()
        guard screenRecordingTrusted else {
            send(["t": "tv.err", "err": "noperm"], from: subscriber)
            return
        }
        tvSubscriber = subscriber
        // Capture start can fail AFTER the permission preflight passed — the common
        // case is the display being asleep (SCShareableContent reports ZERO displays,
        // no error). Surface it to the phone AND keep retrying while the subscription
        // lives: when the display wakes, frames start flowing without the user having
        // to toggle TV off/on. The first frame clears the client-side error state.
        capture.onStartFailed = { [weak self, weak subscriber] in
            DispatchQueue.main.async {
                guard let self, let subscriber, self.tvSubscriber === subscriber else { return }
                self.lastEvent = "tv capture failed"
                HostLog.write("tv capture failed to start (display asleep?) — retrying in 2.5s")
                self.send(["t": "tv.err", "err": "capture"], from: subscriber)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak subscriber] in
                    guard let self, let subscriber, self.tvSubscriber === subscriber,
                          self.connection === subscriber else { return }
                    self.startTV(w: w, h: h, zoom: zoom, follow: follow)
                }
            }
        }
        capture.onState = { [weak self, weak subscriber] lens, cursor in
            DispatchQueue.main.async {
                guard let self, let subscriber, self.tvSubscriber === subscriber,
                      lens.valid else { return }
                var msg: [String: Any] = [
                    "t": "tv.state",
                    "f": lens.follow.rawValue,
                    "fr": lens.resolved.rawValue,
                    "z": lens.zoom,
                    "nat": lens.nat,
                    "m": lens.mag,
                    "sq": lens.seq,
                ]
                // Absence, not a lie — omitted when the cursor is outside the lens or
                // unreadable, so the phone hides its puck instead of parking it in a
                // corner where it is indistinguishable from a real pointer.
                if let c = cursor { msg["cx"] = c.x; msg["cy"] = c.y }
                self.send(msg, from: subscriber)
            }
        }
        capture.start(w: w, h: h, zoom: zoom, follow: TVFollow(wire: follow)) { [weak self, weak subscriber] jpeg in
            guard let self, let subscriber else { return }
            // base64 is JSON-string-safe (A–Z a–z 0–9 + / =), so we build the
            // line by hand on the capture's background queue — no JSONSerialization
            // of an ~80 KB string on .main. .main only writes the finished bytes.
            let b64 = jpeg.base64EncodedString()
            // `s` is the lens sequence this frame was cropped with. The phone echoes it
            // on tv.point so a touch is mapped against the rect the finger could SEE,
            // not the one the host has since moved to.
            let seq = self.capture.lens.seq
            let line = "{\"t\":\"tv.frame\",\"w\":\(w),\"h\":\(h),\"sq\":\(seq),\"d\":\"\(b64)\"}\n"
            self.sendTVFrame(Data(line.utf8), subscriber: subscriber)
        }
    }

    /// Queue a TV frame for the subscriber, newest-wins, one in flight at a time.
    /// On a slow link `.contentProcessed` is delayed (the TCP send buffer is full),
    /// so intermediate frames are DROPPED rather than queued — the stream adapts to
    /// the available bandwidth and never starves the input sharing the connection.
    private func sendTVFrame(_ data: Data, subscriber: NWConnection) {
        DispatchQueue.main.async { [weak self, weak subscriber] in
            guard let self, let subscriber, self.tvSubscriber === subscriber else { return }
            self.tvPendingFrame = data        // replace any older un-sent frame
            self.pumpTVFrame(subscriber: subscriber)
        }
    }

    private func pumpTVFrame(subscriber: NWConnection) {
        guard !tvSendInFlight, let data = tvPendingFrame,
              let conn = connection, conn === subscriber, tvSubscriber === subscriber else { return }
        tvPendingFrame = nil
        // Seal HERE, not at enqueue: newest-wins has just decided which frame
        // actually goes. A frame sealed and then dropped would burn a counter
        // the phone never receives, and every later frame would fail to open.
        guard let data = wireBytes(data) else {
            HostLog.write("RT1: could not seal a TV frame — closing")
            conn.cancel()
            return
        }
        tvSendInFlight = true
        tvSendGen += 1
        let gen = tvSendGen
        conn.send(content: data, completion: .contentProcessed { [weak self, weak subscriber] _ in
            DispatchQueue.main.async {
                guard let self, self.tvSendGen == gen else { return }
                self.tvSendInFlight = false
                guard let subscriber, self.tvSubscriber === subscriber,
                      self.connection === subscriber else { return }
                self.pumpTVFrame(subscriber: subscriber)
            }
        })
        // Stuck-send safety net: if `.contentProcessed` is ever lost, the one-in-flight
        // gate would wedge and the picture would freeze. Recover after a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak subscriber] in
            guard let self, self.tvSendInFlight, self.tvSendGen == gen,
                  let subscriber, self.tvSubscriber === subscriber, self.connection === subscriber else { return }
            self.tvSendInFlight = false
            self.pumpTVFrame(subscriber: subscriber)
        }
    }

    /// Stop the feed. Called on tv.unsub and EVERY connection teardown path
    /// (accept() replacement, .failed/.cancelled, deinit) — the capture must
    /// never outlive its subscriber (privacy + battery).
    private func stopTV() {
        capture.onState = nil    // must not outlive its subscriber, like onStartFailed
        capture.stop()
        tvSubscriber = nil
        tvPendingFrame = nil
        tvSendInFlight = false
    }

    // MARK: Computer audio

    /// Start the system-audio tap for the subscribing connection. Preflights the
    /// same Screen Recording grant TV needs — if it's missing, the phone gets
    /// `aud.err noperm`. Each PCM chunk is base64'd on the capture's BACKGROUND
    /// queue and shipped via sendLine, pinned to the subscriber.
    private func startAudio() {
        stopAudio()
        guard let subscriber = connection else { return }
        refreshScreenRecording()
        guard screenRecordingTrusted else {
            send(["t": "aud.err", "err": "noperm"], from: subscriber)
            return
        }
        audioSubscriber = subscriber
        audioCapture.start { [weak self, weak subscriber] pcm in
            guard let self, let subscriber else { return }
            // base64 is JSON-string-safe, so we build the line by hand on the
            // capture's background queue — .main only writes the finished bytes.
            let b64 = pcm.base64EncodedString()
            let line = "{\"t\":\"aud\",\"r\":\(Int(AudioCapture.sampleRate)),\"d\":\"\(b64)\"}\n"
            self.sendLine(Data(line.utf8), from: subscriber)
        }
    }

    /// Stop the tap. Called on aud.unsub and EVERY connection teardown path —
    /// the capture must never outlive its subscriber (privacy + battery).
    private func stopAudio() {
        audioCapture.stop()
        audioSubscriber = nil
    }

    /// Write a PRE-BUILT newline-terminated line, pinned to `subscriber` (the
    /// connection-identity guard from send(), but skipping JSONSerialization —
    /// the caller already has the bytes). For the TV frame stream.
    private func sendLine(_ data: Data, from subscriber: NWConnection?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let conn = self.connection,
                  subscriber == nil || subscriber === conn else { return }
            guard let wire = self.wireBytes(data) else {
                HostLog.write("RT1: could not seal an outbound line — closing")
                conn.cancel()
                return
            }
            conn.send(content: wire, completion: .contentProcessed { _ in })
        }
    }

    /// Wire bytes for a PRE-BUILT `json ‖ "\n"` line: sealed when the session is
    /// open, unchanged when it is not.
    ///
    /// Must only ever be called from the connection's queue, at the instant the
    /// bytes are written. The counter is sequential and shared with `send`, so
    /// sealing early — or off-queue — reorders the stream and the phone's
    /// decryption never recovers.
    private func wireBytes(_ line: Data) -> Data? {
        guard rt1.isOpen else { return line }
        var json = line
        if json.last == 0x0A { json.removeLast() }
        guard var sealed = try? rt1.seal(json: json) else { return nil }
        sealed.append(0x0A)
        return sealed
    }
}
