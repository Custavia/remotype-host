import CoreGraphics

/// Turning a string into input events is the part that can be wrong in ways a
/// build never catches, so it lives here as pure logic with no CGEvent in sight
/// and gets tested directly. `Injector` only executes the plan.
///
/// Two rules drive the whole thing:
///
///  * **A grapheme cluster must never be split across two events.** "नमस्ते" is
///    six UTF-16 units forming clusters with combining marks; flush half of one
///    and the marks attach to the wrong base, or render as loose dotted circles.
///  * **Some characters are really keys.** Return and Tab carry meaning that a
///    Unicode payload does not — U+000A delivered as text is ignored by most
///    apps, so Enter would silently stop working.
enum PlanStep: Equatable {
    /// Post these UTF-16 units as a Unicode payload (layout-independent).
    case unicode([UniChar])
    /// Post this virtual keycode as a real key press.
    case key(CGKeyCode)
}

enum TextPlan {
    /// Characters that must go through a keycode rather than a Unicode payload.
    ///
    /// `"\r\n"` is listed because in Swift it is a SINGLE Character — CR+LF form
    /// one grapheme cluster. Without it, text pasted from a Windows machine would
    /// miss this table entirely and go out as a Unicode payload, and U+000D
    /// U+000A delivered as text is ignored: every line break in a pasted block
    /// would silently vanish. It maps to one Return, not two, because CRLF is one
    /// line break.
    static let keyLike: [Character: CGKeyCode] = ["\n": 36, "\r": 36, "\r\n": 36, "\t": 48]

    /// Conservative cap on UTF-16 units per event. Long payloads on a single
    /// CGEvent are unreliable in practice; a cluster larger than this is still
    /// emitted whole, because correctness beats the cap.
    static let maxUnitsPerEvent = 16

    static func plan(for s: String) -> [PlanStep] {
        var steps: [PlanStep] = []
        var buf: [UniChar] = []

        func flush() {
            if !buf.isEmpty {
                steps.append(.unicode(buf))
                buf.removeAll(keepingCapacity: true)
            }
        }

        for cluster in s {
            if let kc = keyLike[cluster] {
                flush()
                steps.append(.key(kc))
                continue
            }
            let units = Array(String(cluster).utf16)
            if !buf.isEmpty && buf.count + units.count > maxUnitsPerEvent { flush() }
            buf.append(contentsOf: units)
        }
        flush()
        return steps
    }
}
