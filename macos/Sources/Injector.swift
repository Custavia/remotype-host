import Cocoa
import CoreGraphics

/// Injects input events into macOS via CGEvent / NSEvent. Requires the app to be
/// trusted for Accessibility (System Settings → Privacy & Security → Accessibility).
final class Injector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false
    private var rightDown = false

    /// Modifier flags currently held down on the host (driven by `.modifier`
    /// events). Applied to every key/mouse event so chords like Cmd+Tab work —
    /// the real modifier key stays down until the finger lifts.
    private var heldFlags: CGEventFlags = []

    // MARK: Public entry

    func handle(_ event: InputEvent) {
        switch event {
        case .hello, .ping, .clipFilePush, .clipFileChunk, .clipFileDone, .clipFilePull,
             .ovlTimer:
            break   // session-level / overlay, handled in Server
        case .modifier(let bit, let down):
            setModifierHeld(bit, down: down)
        case .keyChar(let c, let mods):
            if let ch = c.first { typeCharacter(ch, extraMods: mods) }
        case .keyNamed(let name, let mods):
            if let kc = Self.namedKey[name] { postKey(kc, flags: combined(mods)) }
        case .text(let s, let del):
            // Text events carry literal strings (swipe relay, secret type-out).
            // Never fold heldFlags in: a finger resting on a strip modifier
            // would case-corrupt every character or turn it into a shortcut.
            for _ in 0..<max(0, del) { postKey(51, flags: []) } // backspace
            typeLiteralString(s)
        case .mouseMove(let dx, let dy, _):
            moveMouse(dx: dx, dy: dy)
        case .mouseButton(let b, let down, let mods):
            mouseButton(b, down: down, flags: combined(mods))
        case .mouseClick(let b, let mods):
            mouseButton(b, down: true, flags: combined(mods))
            mouseButton(b, down: false, flags: combined(mods))
        case .scroll(let dx, let dy, _):
            scroll(dx: dx, dy: dy)
        case .zoom(let d):
            zoom(d)
        case .consumer(let u):
            if let key = Self.consumerKey[u] { postMediaKey(key) }
        case .clipSet, .clipGet:
            break   // clipboard is the Server's job (NSPasteboard, no injection)
        case .vitalsSub, .vitalsUnsub:
            break   // vitals stream is the Server's job (timer, no injection)
        case .openApp:
            break   // open-app is the Server's job (/usr/bin/open, no injection)
        case .proxArm, .proxDisarm:
            break   // walk-away lock is the Server's job (BLE monitor, no injection)
        case .ovlMode, .ovlMove, .ovlInk, .ovlClear, .ovlCursor:
            break   // Spotlight overlay is the Server's job (OverlayController, no injection)
        case .tvSub, .tvUnsub, .tvFollow, .tvZoom, .tvPan, .tvPoint:
            break   // TV mode is the Server's job (CaptureController, no injection)
        case .edgeArm, .edgeDisarm, .edgeRelease, .edgeEnter:
            break   // MCM edge-flow is the Server's job (EdgeDetector, no injection)
        case .audioSub, .audioUnsub:
            break   // computer audio is the Server's job (AudioCapture, no injection)
        case .castScanSub, .castScanUnsub, .castReach, .castStart, .castStop,
             .castPin, .castQuality, .castVolume, .castDisplay, .castSig:
            break   // casting is the Server's job (CastDiscovery/CastSession, no injection)
        case .permFix:
            break   // permission Fix is the Server's job (opens System Settings, no injection)
        }
    }

    /// Press or release a real modifier key on the host and track its flag.
    private func setModifierHeld(_ bit: Int, down: Bool) {
        let (flag, keycode): (CGEventFlags, CGKeyCode)
        switch bit {
        case Mod.ctrl:  (flag, keycode) = (.maskControl, 59)
        case Mod.shift: (flag, keycode) = (.maskShift, 56)
        case Mod.alt:   (flag, keycode) = (.maskAlternate, 58)
        case Mod.gui:   (flag, keycode) = (.maskCommand, 55)
        default: return
        }
        if down { heldFlags.insert(flag) } else { heldFlags.remove(flag) }
        let e = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down)
        e?.flags = heldFlags
        e?.post(tap: .cgSessionEventTap)
    }

    /// Per-event modifier flags = the latched flags from the wire ∪ held flags.
    private func combined(_ mods: Int) -> CGEventFlags { flags(from: mods).union(heldFlags) }

    /// Release every held modifier (called when the client disconnects, so a
    /// held Cmd/Shift can't get stuck down on the host).
    func releaseAllModifiers() {
        for bit in [Mod.ctrl, Mod.shift, Mod.alt, Mod.gui] where !heldFlags.isEmpty {
            setModifierHeld(bit, down: false)
        }
        heldFlags = []
        if leftDown { mouseButton(0, down: false, flags: []) }
        if rightDown { mouseButton(1, down: false, flags: []) }
    }

    // MARK: Keyboard

    private func typeCharacter(_ ch: Character, extraMods: Int) {
        // Characters that are really KEYS keep the keycode path — Return and Tab
        // carry meaning a Unicode payload does not: U+000A posted as text is
        // ignored by most apps, so Enter would silently stop working.
        if let keycode = TextPlan.keyLike[ch] {
            postKey(keycode, flags: combined(extraMods))
            return
        }
        // Shortcuts are defined by key POSITION, not by character, so a chord has
        // to go through the virtual keycode. Cmd+C means "the key at C's spot".
        if shortcutActive(extraMods) {
            guard let (keycode, needsShift) = Self.charKey[ch] else { return }
            var f = combined(extraMods)
            if needsShift { f.insert(.maskShift) }
            postKey(keycode, flags: f)
            return
        }
        // Plain typing goes as Unicode, which is layout-independent.
        postUnicode(String(ch))
    }

    /// Type literal text, ignoring held modifiers entirely (used for `.text`
    /// events — swipe relay, secret type-out — where chord flags are never
    /// meaningful and would case-corrupt every character).
    private func typeLiteralString(_ s: String) {
        for step in TextPlan.plan(for: s) {
            switch step {
            case .key(let kc):      postKey(kc, flags: [])
            case .unicode(let buf): postUnicodeUnits(buf)
            }
        }
    }

    /// Post text as a Unicode payload rather than as key positions.
    ///
    /// This is the whole reason non-English typing works. Bluetooth HID and the
    /// virtual-keycode path both say "the key at position N was pressed" and let
    /// the receiving layout decide what that means — which is why the old
    /// hardcoded US `charKey` table silently dropped ñ, é, £ and every
    /// Devanagari letter, and mistyped even plain ASCII on an AZERTY Mac.
    /// `keyboardSetUnicodeString` instead hands the system the exact characters.
    /// Windows already does this via `KEYEVENTF_UNICODE`; this makes macOS match.
    private func postUnicode(_ s: String) {
        for step in TextPlan.plan(for: s) {
            switch step {
            case .key(let kc):      postKey(kc, flags: [])
            case .unicode(let buf): postUnicodeUnits(buf)
            }
        }
    }

    /// Post one already-chunked payload. Splitting and cluster safety are
    /// `TextPlan`'s job, which is why they are testable and this is not.
    private func postUnicodeUnits(_ buf: [UniChar]) {
        guard !buf.isEmpty else { return }
        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
            else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf)
            e.post(tap: .cgSessionEventTap)
        }
    }

    /// True when a chord modifier is in play, from this event or from a finger
    /// resting on a strip modifier. Shift alone is not a shortcut — it is just
    /// capitalisation, which the Unicode path already carries.
    private func shortcutActive(_ mods: Int) -> Bool {
        let f = combined(mods)
        return !f.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
    }



    private func postKey(_ keycode: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cgSessionEventTap)
    }

    private func flags(from mods: Int) -> CGEventFlags {
        var f = CGEventFlags()
        if mods & Mod.ctrl != 0 { f.insert(.maskControl) }
        if mods & Mod.shift != 0 { f.insert(.maskShift) }
        if mods & Mod.alt != 0 { f.insert(.maskAlternate) }
        if mods & Mod.gui != 0 { f.insert(.maskCommand) }
        return f
    }

    // MARK: Mouse

    private func currentPos() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func clamp(_ p: CGPoint) -> CGPoint {
        // Multi-monitor correctness. The old clamp boxed the cursor into
        // [0, maxX) x [0, maxY): a display arranged LEFT of (or above) the main
        // one lives at NEGATIVE CG coordinates and was simply unreachable —
        // "unable to move the cursor from one screen to another". It also mixed
        // Cocoa (bottom-left) NSScreen frames into CG (top-left) event space.
        // Use CG's own display bounds: pass any point inside a display through,
        // and snap dead-zone points (the union's empty corners) to the nearest
        // display edge.
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let displays = (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }
        guard !displays.isEmpty else { return p }
        if displays.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDist = CGFloat.greatestFiniteMagnitude
        for d in displays {
            let q = CGPoint(x: min(max(d.minX, p.x), d.maxX - 1),
                            y: min(max(d.minY, p.y), d.maxY - 1))
            let dist = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if dist < bestDist { bestDist = dist; best = q }
        }
        return best
    }

    private func moveMouse(dx: Int, dy: Int) {
        let p = clamp(CGPoint(x: currentPos().x + CGFloat(dx), y: currentPos().y + CGFloat(dy)))
        let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        let button: CGMouseButton = rightDown ? .right : .left
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.post(tap: .cgSessionEventTap)
    }

    private func mouseButton(_ b: Int, down: Bool, flags: CGEventFlags) {
        let pos = currentPos()
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case 1: button = .right; type = down ? .rightMouseDown : .rightMouseUp; rightDown = down
        case 2: button = .center; type = down ? .otherMouseDown : .otherMouseUp
        default: button = .left; type = down ? .leftMouseDown : .leftMouseUp; leftDown = down
        }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: button)
        e?.flags = flags
        e?.post(tap: .cgSessionEventTap)
    }

    private func scroll(dx: Int, dy: Int) {
        // wheel1 = vertical, wheel2 = horizontal.
        let e = CGEvent(scrollWheelEvent2Source: source, units: .line,
                        wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        e?.flags = heldFlags
        e?.post(tap: .cgSessionEventTap)
    }

    /// Pinch zoom — synthesized as Cmd+"=" / Cmd+"-" keystrokes, which reliably
    /// zoom browsers, Preview, editors, etc. on macOS. (Cmd+scroll does not zoom
    /// most Mac apps; the real magnify gesture isn't publicly synthesizable.)
    private func zoom(_ delta: Int) {
        guard delta != 0 else { return }
        let keycode: CGKeyCode = delta > 0 ? 24 : 27 // '=' (zoom in) or '-' (zoom out)
        let steps = min(abs(delta), 4)
        for _ in 0..<steps {
            postKey(keycode, flags: heldFlags.union(.maskCommand))
        }
    }

    // MARK: Media (Consumer Control)

    private func postMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let flags: NSEvent.ModifierFlags = isDown ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00)
            let data1 = (Int(key) << 16) | ((isDown ? 0xA : 0xB) << 8)
            guard let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1
            ) else { continue }
            ev.cgEvent?.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Keycode tables (US ANSI)

extension Injector {
    /// Named special keys → macOS virtual keycodes. Unknown names are a safe
    /// no-op (lookup miss in `handle`), so older hosts ignore newer vocabulary.
    static let namedKey: [String: CGKeyCode] = [
        "tab": 48, "enter": 36, "return": 36, "backspace": 51, "space": 49, "esc": 53, "escape": 53,
        // Grave/backtick — kVK_ANSI_Grave. Used for Cmd+` window cycling (switch
        // windows of the focused app); the held Cmd is folded in via heldFlags.
        "grave": 50,
        // Forward-delete (the dictate mini-keyboard's ⌦) — kVK_ForwardDelete.
        "fdel": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        // Keypad cluster (Numpad mode) — kVK_ANSI_Keypad*: real keypad
        // keycodes so spreadsheets see a genuine numpad.
        "kp0": 82, "kp1": 83, "kp2": 84, "kp3": 85, "kp4": 86,
        "kp5": 87, "kp6": 88, "kp7": 89, "kp8": 91, "kp9": 92,
        "kpdot": 65, "kpmul": 67, "kpplus": 69, "kpdiv": 75, "kpenter": 76, "kpminus": 78,
    ]

    /// Consumer usages → NX media key codes. Unknown names are a safe no-op
    /// (lookup miss in `handle`), so older hosts ignore newer vocabulary.
    static let consumerKey: [String: Int32] = [
        "playpause": 16, "next": 17, "prev": 18, "mute": 7,
        "volup": 0, "voldown": 1, "brightup": 2, "brightdown": 3,
        // Media-mode scrub: NX_KEYTYPE_FAST / NX_KEYTYPE_REWIND.
        "ffwd": 19, "rewind": 20,
    ]

    /// Character → (virtual keycode, needs Shift) on a US layout.
    static let charKey: [Character: (CGKeyCode, Bool)] = {
        var m: [Character: (CGKeyCode, Bool)] = [:]
        let letters: [(Character, CGKeyCode)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5), ("h", 4),
            ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31), ("p", 35),
            ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32), ("v", 9), ("w", 13), ("x", 7),
            ("y", 16), ("z", 6),
        ]
        for (c, kc) in letters {
            m[c] = (kc, false)
            m[Character(c.uppercased())] = (kc, true)
        }
        // Digit, shifted symbol, keycode.
        let digits: [(Character, Character, CGKeyCode)] = [
            ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21), ("5", "%", 23),
            ("6", "^", 22), ("7", "&", 26), ("8", "*", 28), ("9", "(", 25), ("0", ")", 29),
        ]
        for (d, s, kc) in digits {
            m[d] = (kc, false)
            m[s] = (kc, true)
        }
        // Punctuation: unshifted, shifted, keycode.
        let punct: [(Character, Character, CGKeyCode)] = [
            ("`", "~", 50), ("-", "_", 27), ("=", "+", 24), ("[", "{", 33), ("]", "}", 30),
            ("\\", "|", 42), (";", ":", 41), ("'", "\"", 39), (",", "<", 43), (".", ">", 47),
            ("/", "?", 44),
        ]
        for (u, s, kc) in punct {
            m[u] = (kc, false)
            m[s] = (kc, true)
        }
        m[" "] = (49, false)
        m["\n"] = (36, false)
        m["\t"] = (48, false)
        return m
    }()
}
