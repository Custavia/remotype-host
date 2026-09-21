import Foundation

/// A decoded input event from the iOS app. Mirrors PROTOCOL.md.
enum InputEvent {
    case hello(name: String, version: Int)
    /// Liveness probe: lets the phone distinguish a half-open TCP link (doze,
    /// AP roam) from a healthy quiet one. Reply-only, carries nothing.
    case ping
    case clipFilePush(id: String, name: String, size: Int)
    case clipFileChunk(id: String, data: String)
    case clipFileDone(id: String)
    case clipFilePull(id: String)
    case keyChar(char: String, mods: Int)
    case keyNamed(name: String, mods: Int)
    case text(string: String, del: Int)
    case modifier(bit: Int, down: Bool)
    case mouseMove(dx: Int, dy: Int, mods: Int)
    case mouseButton(button: Int, down: Bool, mods: Int)
    case mouseClick(button: Int, mods: Int)
    case scroll(dx: Int, dy: Int, mods: Int)
    case zoom(delta: Int)
    case consumer(usage: String)
    // Clipboard bridge (protocol v2) — control events, not injection: the
    // Server answers these itself via NSPasteboard. A pre-v2 host's parse
    // hits the default branch (nil) and drainLines skips the line, so older
    // hosts safely ignore clip.* vocabulary.
    case clipSet(string: String)
    case clipGet(id: Int?)   // optional correlation id, echoed in the reply
    // Vitals stream — control events like clip.*: the Server
    // starts/stops its 1.5 s `{"t":"vitals"}` timer; nothing is injected.
    // Older hosts hit the default branch (nil) and skip the line safely.
    case vitalsSub
    case vitalsUnsub
    // Open app (Macro deck, ) — a control event like clip.*: the
    // Server spawns `/usr/bin/open -a <name>` itself (argument array, never
    // a shell); nothing is injected. Older hosts hit the default branch
    // (nil) and skip the line safely.
    case openApp(name: String)
    // Walk-away lock — control events like clip.*: the Server
    // (re)starts/stops its ProximityMonitor (BLE central + RSSI evaluator);
    // nothing is injected. `tok` is the phone's hex-encoded session token,
    // `near` the RSSI threshold in dBm, `grace` the seconds below threshold
    // before locking. Older hosts hit the default branch (nil) and skip the
    // line safely.
    case proxArm(token: Data, near: Int, grace: Int)
    case proxDisarm
    // Spotlight overlay — control events like clip.*: the Server
    // routes these to its OverlayController (a click-through, full-screen
    // overlay window). Nothing is injected and Accessibility is NOT required —
    // an overlay is just a window — but they ARE v2-gated like every other
    // control event. Coords are normalized 0–1, origin TOP-LEFT, y down (see
    // PROTOCOL.md). Older hosts hit the default branch (nil) and skip the line.
    case ovlMode(mode: String, rf: Double, dim: Int, col: String?)
    case ovlMove(x: Double, y: Double)
    case ovlInk(phase: String, x: Double, y: Double)
    case ovlClear
    /// Audience countdown on the presentation display. The phone owns the clock
    /// and pushes remaining seconds; the host only renders (§Presenter).
    case ovlTimer(on: Bool, secs: Int, warn: Bool)
    // Move the REAL system cursor to a normalized point — Spotlight's "position
    // the cursor, then double-tap to highlight" phase. Warps the cursor (no
    // Accessibility needed), so it stays in the same permission-free family.
    case ovlCursor(x: Double, y: Double)
    // TV mode — control events like vitals.*: the Server starts/
    // stops a CaptureController that streams a small magnified slice of the
    // screen (`{"t":"tv.frame"}`) following the cursor. v2-gated; needs the Mac's
    // Screen Recording grant (the Server answers tv.err if it's missing). `w`/`h`
    // are the output pixel size, `z` the magnification. Older hosts hit the
    // default branch (nil) and skip the line safely.
    case tvSub(w: Int, h: Int, zoom: Double, follow: String)
    case tvUnsub
    // Change what the magnified lens follows live, without restarting the stream:
    // f ∈ "auto" | "cursor" | "caret" | "full".
    case tvFollow(mode: String)
    // Change the magnification live (z = zoom factor).
    case tvZoom(zoom: Double)
    // Manual pan (steer the lens by hand) — dx/dy are normalized display-fraction
    // deltas; enters manual-follow on the host. Coalesced realtime while dragging.
    case tvPan(dx: Double, dy: Double)
    /// Absolute pointing inside the current lens. `seq` echoes the lens the finger
    /// was actually touching; 0 = "no frame rendered yet, use the live lens".
    case tvPoint(x: Double, y: Double, seq: Int)
    // MCM edge-flow (MCM.md §3) — host detects the real cursor at an armed edge;
    // the phone commits a switch and parks/warps via release/enter.
    case edgeArm(sides: [String])
    case edgeDisarm
    case edgeRelease(to: String, y: Double)
    case edgeEnter(from: String, y: Double)
    // Computer audio — control events like vitals.*: the Server
    // starts/stops an AudioCapture (ScreenCaptureKit system-audio tap) that
    // streams `{"t":"aud"}` PCM chunks to the phone. v2-gated; needs the Mac's
    // Screen Recording grant (same as TV). Older hosts hit the default branch
    // (nil) and skip the line safely.
    case audioSub
    case audioUnsub
    // Screen casting (CASTING.md, slice 1) — control events like vitals.*: the
    // Server drives its CastDiscovery (sink browse → `cast.targets` snapshots)
    // and CastSession (the one NATIVE AirPlay session per host); nothing is
    // injected. Older hosts hit the default branch (nil) and skip the line
    // safely; a host that answers `hi` without `"cast":1` never receives these.
    case castScanSub
    case castScanUnsub
    case castReach(addr: String, port: Int, rid: String)
    case castStart(rid: String, targetId: String, targetType: String,
                   addr: String?, port: Int?, audio: Bool, quality: String,
                   display: String?, force: Bool)
    case castStop(sid: String)
    case castPin(sid: String, code: String)
    case castQuality(sid: String, quality: String, maxRung: String?)
    case castVolume(sid: String, level: Double)
    case castDisplay(sid: String, id: String)
    // Cast DIRECT (§6.6): the phone relays a WebRTC signaling message between the
    // receiver and the host's streamer. `kind` ∈ "answer" | "ice" (offer/ice flow
    // host→phone→receiver; answer/ice flow receiver→phone→host). `token` (§14.2)
    // pins the message to the session; `data` is the opaque SDP/ICE JSON the host
    // forwards to its sidecar verbatim — never parsed or logged (§14.6).
    case castSig(sid: String, token: String, kind: String, data: [String: Any])
    // Phone tapped "Fix" on a missing host permission → open the matching System
    // Settings pane. id ∈ "accessibility" | "screen".
    case permFix(id: String)

    /// Parse one newline-delimited JSON object.
    static func parse(_ line: Data) -> InputEvent? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let t = obj["t"] as? String
        else { return nil }

        let mods = (obj["mods"] as? Int) ?? 0
        switch t {
        case "hello":
            return .hello(name: (obj["name"] as? String) ?? "iPhone",
                          version: (obj["v"] as? Int) ?? 1)
        case "ping":
            return .ping
        case "key":
            if let c = obj["c"] as? String, !c.isEmpty { return .keyChar(char: c, mods: mods) }
            if let k = obj["k"] as? String { return .keyNamed(name: k, mods: mods) }
            return nil
        case "text":
            return .text(string: (obj["s"] as? String) ?? "", del: (obj["del"] as? Int) ?? 0)
        case "mod":
            return .modifier(bit: (obj["b"] as? Int) ?? 0, down: (obj["down"] as? Bool) ?? false)
        case "zoom":
            return .zoom(delta: (obj["d"] as? Int) ?? 0)
        case "mm":
            return .mouseMove(dx: (obj["dx"] as? Int) ?? 0, dy: (obj["dy"] as? Int) ?? 0, mods: mods)
        case "mb":
            return .mouseButton(button: (obj["b"] as? Int) ?? 0, down: (obj["down"] as? Bool) ?? false, mods: mods)
        case "mc":
            return .mouseClick(button: (obj["b"] as? Int) ?? 0, mods: mods)
        case "sc":
            return .scroll(dx: (obj["dx"] as? Int) ?? 0, dy: (obj["dy"] as? Int) ?? 0, mods: mods)
        case "cc":
            guard let u = obj["u"] as? String else { return nil }
            return .consumer(usage: u)
        case "clip.set":
            guard let s = obj["s"] as? String else { return nil }
            return .clipSet(string: s)
        case "clip.get":
            return .clipGet(id: obj["id"] as? Int)
        case "clip.file.push":
            return .clipFilePush(id: "\(obj["id"] ?? "")",
                                 name: (obj["name"] as? String) ?? "",
                                 size: (obj["size"] as? Int) ?? 0)
        case "clip.file.chunk":
            return .clipFileChunk(id: "\(obj["id"] ?? "")",
                                  data: (obj["data"] as? String) ?? "")
        case "clip.file.done":
            return .clipFileDone(id: "\(obj["id"] ?? "")")
        case "clip.file.pull":
            return .clipFilePull(id: "\(obj["id"] ?? "")")
        case "vitals.sub":
            return .vitalsSub
        case "vitals.unsub":
            return .vitalsUnsub
        case "open":
            guard let app = obj["app"] as? String else { return nil }
            return .openApp(name: app)
        case "prox.arm":
            // A malformed/empty token can't range anything — reject the line
            // (nil) rather than arm against nothing.
            guard let hex = obj["tok"] as? String, let token = Data(hex: hex),
                  !token.isEmpty else { return nil }
            // The host performs the irreversible screen-lock, so it validates
            // its own trigger parameters rather than trusting the wire. A
            // buggy/forked/older client could send grace:0 (locks on the first
            // below-threshold sample, defeating the PRIMARY false-lock guard)
            // or an absurd `near` (every sample counts as out-of-range). Clamp
            // to plausible bands: grace ≥ 10 s, near within −40…−100 dBm.
            let near = min(max((obj["near"] as? Int) ?? -78, -100), -40)
            let grace = max((obj["grace"] as? Int) ?? 30, 10)
            return .proxArm(token: token, near: near, grace: grace)
        case "prox.disarm":
            return .proxDisarm
        case "ovl.mode":
            // `m` is required; the rest carry defaults so a terse client works.
            // `as? Double` accepts any JSON number (Int or fractional); clamping
            // is the OverlayController's job (it owns the screen).
            guard let m = obj["m"] as? String else { return nil }
            let rf = (obj["rf"] as? Double) ?? 0.12
            let dim = (obj["dim"] as? Int) ?? 68
            return .ovlMode(mode: m, rf: rf, dim: dim, col: obj["col"] as? String)
        case "ovl.move":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
            return .ovlMove(x: x, y: y)
        case "ovl.ink":
            guard let p = obj["p"] as? String,
                  let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
            return .ovlInk(phase: p, x: x, y: y)
        case "ovl.clear":
            return .ovlClear
        case "ovl.timer":
            return .ovlTimer(on: (obj["on"] as? Bool) ?? false,
                             secs: (obj["secs"] as? Int) ?? 0,
                             warn: (obj["warn"] as? Bool) ?? false)
        case "ovl.cursor":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
            return .ovlCursor(x: x, y: y)
        case "tv.sub":
            // Output geometry + magnification + follow mode; terse clients can
            // omit (defaults). `as? Double` accepts any JSON number for z.
            return .tvSub(w: (obj["w"] as? Int) ?? 360,
                          h: (obj["h"] as? Int) ?? 480,
                          zoom: (obj["z"] as? Double) ?? 2.0,
                          follow: (obj["f"] as? String) ?? "auto")
        case "tv.unsub":
            return .tvUnsub
        case "tv.follow":
            return .tvFollow(mode: (obj["f"] as? String) ?? "auto")
        case "tv.zoom":
            return .tvZoom(zoom: (obj["z"] as? Double) ?? 2.0)
        case "tv.pan":
            return .tvPan(dx: (obj["dx"] as? Double) ?? 0, dy: (obj["dy"] as? Double) ?? 0)
        case "tv.point":
            // REQUIRE both. tv.pan's `?? 0` is right for a delta and catastrophic for
            // an absolute point: a missing field would warp the cursor to the lens's
            // top-left corner instead of doing nothing.
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
            return .tvPoint(x: x, y: y, seq: (obj["sq"] as? Int) ?? 0)
        case "edge.arm":
            return .edgeArm(sides: (obj["sides"] as? [String]) ?? [])
        case "edge.disarm":
            return .edgeDisarm
        case "edge.release":
            return .edgeRelease(to: (obj["to"] as? String) ?? "", y: (obj["y"] as? Double) ?? 0)
        case "edge.enter":
            return .edgeEnter(from: (obj["from"] as? String) ?? "", y: (obj["y"] as? Double) ?? 0)
        case "aud.sub":
            return .audioSub
        case "aud.unsub":
            return .audioUnsub
        case "cast.scan.sub":
            return .castScanSub
        case "cast.scan.unsub":
            return .castScanUnsub
        case "cast.reach":
            guard let addr = obj["addr"] as? String, !addr.isEmpty,
                  let port = obj["port"] as? Int, (1...65535).contains(port),
                  let rid = obj["rid"] as? String else { return nil }
            return .castReach(addr: addr, port: port, rid: rid)
        case "cast.start":
            guard let rid = obj["rid"] as? String,
                  let target = obj["target"] as? [String: Any],
                  let id = target["id"] as? String, !id.isEmpty,
                  let type = target["type"] as? String else { return nil }
            return .castStart(rid: rid, targetId: id, targetType: type,
                              addr: target["addr"] as? String,
                              port: target["port"] as? Int,
                              audio: (obj["audio"] as? Bool) ?? true,
                              quality: (obj["quality"] as? String) ?? "auto",
                              display: obj["display"] as? String,
                              force: (obj["force"] as? Bool) ?? false)
        case "cast.stop":
            guard let sid = obj["sid"] as? String else { return nil }
            return .castStop(sid: sid)
        case "cast.pin":
            // The host TYPES this into a system dialog — digits only, bounded.
            guard let sid = obj["sid"] as? String, let code = obj["code"] as? String,
                  (1...8).contains(code.count),
                  code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return .castPin(sid: sid, code: code)
        case "cast.quality":
            guard let sid = obj["sid"] as? String else { return nil }
            return .castQuality(sid: sid, quality: (obj["quality"] as? String) ?? "auto",
                                maxRung: obj["maxRung"] as? String)
        case "cast.volume":
            guard let sid = obj["sid"] as? String, let level = obj["level"] as? Double
            else { return nil }
            return .castVolume(sid: sid, level: min(max(level, 0), 1))
        case "cast.display":
            guard let sid = obj["sid"] as? String, let id = obj["id"] as? String
            else { return nil }
            return .castDisplay(sid: sid, id: id)
        case "cast.sig":
            guard let sid = obj["sid"] as? String, let token = obj["token"] as? String,
                  let kind = obj["kind"] as? String, let data = obj["data"] as? [String: Any]
            else { return nil }
            return .castSig(sid: sid, token: token, kind: kind, data: data)
        case "perm.fix":
            guard let id = obj["id"] as? String else { return nil }
            return .permFix(id: id)
        default:
            return nil
        }
    }
}

extension Data {
    /// Decode a lowercase/uppercase hex string into bytes. Returns nil on odd
    /// length or any non-hex character.
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue
            else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }
}

/// Modifier bits shared with the iOS app.
enum Mod {
    static let ctrl = 1
    static let shift = 2
    static let alt = 4
    static let gui = 8
}
