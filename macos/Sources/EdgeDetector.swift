import CoreGraphics
import Foundation

/// Host-side edge detection for MCM edge-flow (Flow/Synergy model). Polls the
/// cursor ONLY while armed (off the main queue), reports when it hits an armed
/// edge, and warps/parks the cursor on switch. One per connection; `disarm()` on
/// every teardown path — no leaked always-on timer (the bug in the reverted attempt).
final class EdgeDetector {
    private let queue = DispatchQueue(label: "com.custavia.remotype.edge")
    private var timer: DispatchSourceTimer?
    private var sides: Set<String> = []
    private var last = ""

    /// Fired on the edge queue when the cursor hits an armed edge (side, y 0…1).
    var onEdge: ((String, Double) -> Void)?
    /// Fired when the cursor leaves the edge before a commit.
    var onCancel: (() -> Void)?

    func arm(_ s: [String]) {
        queue.async {
            self.sides = Set(s)
            self.last = ""
            if s.isEmpty { self.stopLocked(); return }
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60Hz, armed only
                t.setEventHandler { [weak self] in self?.tick() }
                self.timer = t
                t.resume()
            }
        }
    }

    func disarm() { queue.async { self.stopLocked() } }

    private func stopLocked() {
        timer?.cancel(); timer = nil; sides = []; last = ""
    }

    /// Warp the cursor onto the `from` edge at y — the cursor arrives here.
    func warp(from: String, y: Double) {
        CGWarpMouseCursorPosition(edgePoint(from, y, CGDisplayBounds(CGMainDisplayID())))
    }

    /// Park the cursor a hair inside the `to` edge (no instant re-fire) + disarm.
    func park(to: String, y: Double) {
        var p = edgePoint(to, y, CGDisplayBounds(CGMainDisplayID()))
        switch to {
        case "left": p.x += 4
        case "right": p.x -= 4
        case "top": p.y += 4
        case "bottom": p.y -= 4
        default: break
        }
        CGWarpMouseCursorPosition(p)
        disarm()
    }

    private func edgePoint(_ side: String, _ y: Double, _ b: CGRect) -> CGPoint {
        switch side {
        case "left":   return CGPoint(x: b.minX, y: b.minY + y * b.height)
        case "right":  return CGPoint(x: b.maxX - 1, y: b.minY + y * b.height)
        case "top":    return CGPoint(x: b.minX + y * b.width, y: b.minY)
        case "bottom": return CGPoint(x: b.minX + y * b.width, y: b.maxY - 1)
        default:       return CGPoint(x: b.midX, y: b.midY)
        }
    }

    private func tick() {
        guard let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(CGMainDisplayID())
        var hit = ""
        if sides.contains("left"), loc.x <= b.minX { hit = "left" }
        else if sides.contains("right"), loc.x >= b.maxX - 1 { hit = "right" }
        else if sides.contains("top"), loc.y <= b.minY { hit = "top" }
        else if sides.contains("bottom"), loc.y >= b.maxY - 1 { hit = "bottom" }

        if !hit.isEmpty, hit != last {
            last = hit
            let yn = (hit == "left" || hit == "right")
                ? (loc.y - b.minY) / b.height
                : (loc.x - b.minX) / b.width
            onEdge?(hit, min(max(yn, 0), 1))
        } else if hit.isEmpty, !last.isEmpty {
            last = ""
            onCancel?()
        }
    }
}
