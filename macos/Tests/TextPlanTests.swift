// Tests for TextPlan — the logic that decides how a string becomes input events.
//
// Deliberately standalone rather than an XCTest target: it needs no Accessibility
// grant, no window server and no signed app, so it runs anywhere, including CI.
//
//   swiftc -o /tmp/textplan Sources/TextPlan.swift Tests/TextPlanTests.swift && /tmp/textplan
//
// What it cannot prove is that macOS renders the payload — that needs the real
// host with Accessibility granted and a text field to type into. What it does
// prove is every way the plan itself can be wrong, which is where the bugs are:
// a grapheme split in half, Return smuggled into a text payload, a chunk over
// the cap, or a character silently dropped the way the old US table dropped ñ.

import CoreGraphics
import Foundation

var failures = 0

func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond {
        print("  ok   \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

/// Reassemble a plan back into the text it would produce, so we can assert that
/// nothing was dropped, duplicated or reordered.
func rendered(_ steps: [PlanStep]) -> String {
    var out = ""
    for s in steps {
        switch s {
        case .unicode(let units): out += String(utf16CodeUnits: units, count: units.count)
        case .key(let kc):        out += (kc == 36 ? "\n" : kc == 48 ? "\t" : "?")
        }
    }
    return out
}

func unicodeChunks(_ steps: [PlanStep]) -> [[UniChar]] {
    steps.compactMap { if case .unicode(let u) = $0 { return u } else { return nil } }
}

@main
enum TextPlanTests {
    static func main() {
        print("TextPlan")

        // --- The bug this whole change exists to fix -------------------------------
        // The old macOS path mapped characters through a hardcoded US table and used
        // `guard let ... else { return }`, so anything absent typed NOTHING at all.
        for sample in ["ñ", "é", "ü", "ç", "£", "€", "日本語", "नमस्ते", "मेरो नाम", "café", "Ω≈ç√"] {
            let plan = TextPlan.plan(for: sample)
            check("survives \(sample)", rendered(plan) == sample,
                  "got \(rendered(plan).debugDescription), expected \(sample.debugDescription)")
        }

        // --- Grapheme clusters must never be split across events --------------------
        // "नमस्ते" is several scalars per cluster. Split one and the combining marks
        // attach to the wrong base, or render as loose dotted circles.
        do {
            let s = String(repeating: "नमस्ते", count: 6)   // well over the per-event cap
            let plan = TextPlan.plan(for: s)
            check("long Devanagari round-trips", rendered(plan) == s)
            // Every chunk must itself be a whole number of clusters: re-decoding a chunk
            // and re-encoding it must be lossless and must not start with a combining mark.
            var allWhole = true
            for chunk in unicodeChunks(plan) {
                let text = String(utf16CodeUnits: chunk, count: chunk.count)
                if Array(text.utf16) != chunk { allWhole = false }
                if let first = text.unicodeScalars.first,
                   first.properties.isGraphemeExtend { allWhole = false }
            }
            check("no chunk starts mid-cluster", allWhole)
            check("actually split into several events", unicodeChunks(plan).count > 1,
                  "got \(unicodeChunks(plan).count) chunk(s)")
        }

        // --- Emoji, including multi-scalar ZWJ sequences ----------------------------
        do {
            let s = "👩‍👩‍👧‍👦 family, 🇳🇵 flag, é"     // one cluster is 11 UTF-16 units
            let plan = TextPlan.plan(for: s)
            check("emoji + ZWJ round-trips", rendered(plan) == s)
            for chunk in unicodeChunks(plan) {
                let text = String(utf16CodeUnits: chunk, count: chunk.count)
                check("chunk is whole clusters", Array(text.utf16) == chunk)
            }
        }

        // --- Oversized single cluster is emitted whole ------------------------------
        // Correctness beats the cap: a cluster longer than the chunk size must not be
        // cut in half just to respect it.
        do {
            let big = "👨‍👩‍👧‍👦"                       // 11 UTF-16 units, cap is 16 but test the rule
            let plan = TextPlan.plan(for: big)
            check("oversized cluster stays in one event", unicodeChunks(plan).count == 1)
            check("oversized cluster intact", rendered(plan) == big)
        }

        // --- Return and Tab stay real keys ------------------------------------------
        // U+000A as a Unicode payload is ignored by most apps: Enter would silently
        // stop working, which is exactly the bug the Windows host documents.
        do {
            let plan = TextPlan.plan(for: "a\nb\tc")
            check("Return is a key, not text", plan.contains(.key(36)))
            check("Tab is a key, not text", plan.contains(.key(48)))
            check("newline never inside a unicode chunk",
                  !unicodeChunks(plan).contains { $0.contains(10) })
            check("text around them is preserved", rendered(plan) == "a\nb\tc")
            check("order preserved", plan == [.unicode(Array("a".utf16)), .key(36),
                                              .unicode(Array("b".utf16)), .key(48),
                                              .unicode(Array("c".utf16))])
        }

        // --- Chunk cap respected for ordinary text ----------------------------------
        do {
            let s = String(repeating: "x", count: 100)
            let plan = TextPlan.plan(for: s)
            check("plain ASCII round-trips", rendered(plan) == s)
            check("every chunk within cap",
                  unicodeChunks(plan).allSatisfy { $0.count <= TextPlan.maxUnitsPerEvent })
        }

        // --- Degenerate input --------------------------------------------------------
        check("empty string produces nothing", TextPlan.plan(for: "").isEmpty)
        check("lone newline is one key", TextPlan.plan(for: "\n") == [.key(36)])
        // Swift treats CR+LF as ONE Character, so this is the case that slipped past
        // the key table and would have sent a line break as ignored text.
        check("CRLF is one Return, not text", TextPlan.plan(for: "\r\n") == [.key(36)])
        check("CRLF inside a block still breaks lines",
              TextPlan.plan(for: "a\r\nb") == [.unicode(Array("a".utf16)), .key(36),
                                              .unicode(Array("b".utf16))])

        print(failures == 0 ? "\nPASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)

    }
}
