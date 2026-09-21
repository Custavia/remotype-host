import AppKit
import QuartzCore

/// The Spotlight overlay. A click-through, full-screen window the
/// phone drives to highlight part of the screen for an audience — visible in
/// screen-share/recordings (a physical laser is not). Four sub-modes:
///
///   • spotlight — dim the screen except a circular cutout that follows the
///     pointer.   • square — same, rectangular cutout.   • pointer — a styled
///     dot, no dim.   • annotate — freehand ink the user draws on screen.
///
/// It is PURELY a window — no event injection — so it needs no Accessibility
/// grant and never blocks the presenter's real clicks (`ignoresMouseEvents`).
/// Everything is layer-backed and updated inside an action-disabled
/// `CATransaction`, so pointer tracking is a cheap per-frame path/position swap
/// (no implicit-animation lag) — smooth at the ~60 `ovl.move`/s the phone sends.
///
/// All methods MUST be called on the main thread (the Server's connection queue
/// is .main, and AppKit/Core Animation require it) — a convention shared with
/// the rest of the host, not enforced by an actor.
final class OverlayController {
    private var panel: NSPanel?
    private var view: OverlayView?
    /// The screen the overlay currently covers — re-resolved on each activation
    /// (the cursor may have moved to the presentation display since last time).
    private var targetScreen: NSScreen?
    private var visible = false

    // Smoothing: the phone's latest target + a display-rate loop that EASES the
    // rendered position (the real cursor while aiming, the overlay while engaged)
    // toward it — smooth regardless of packet timing / finger tremor, and no
    // teleport "jumps". A posted `CGEvent .mouseMoved` (not `CGWarp`) gives
    // jump-free absolute cursor positioning. Strokes (ink) bypass this and follow
    // the finger exactly.
    private var targetN = CGPoint(x: 0.5, y: 0.5)
    private var renderN = CGPoint(x: 0.5, y: 0.5)
    private var drivingCursor = false
    private var smoothTimer: DispatchSourceTimer?
    private let cursorSource = CGEventSource(stateID: .hidSystemState)
    private let smoothing: CGFloat = 0.5

    // MARK: Control surface (called from Server.apply on .main)

    /// Activate a sub-mode (or "off" to hide). Re-targets the screen under the
    /// cursor, applies the clamped params, and fades the window in.
    func setMode(_ m: String, rf: Double, dim: Int, col: String?) {
        guard m != "off" else { reset(); return }
        guard let screen = resolveScreen() else { return }
        ensureWindow()
        retarget(to: screen)
        view?.configure(mode: m,
                        rf: min(max(rf, 0.02), 0.5),
                        dim: min(max(dim, 0), 100),
                        color: Self.color(fromHex: col))
        show()
    }

    /// Engaged: ease the overlay toward this normalized point (smoothed loop).
    func move(x: Double, y: Double) { setTarget(CGPoint(x: x, y: y), cursor: false) }

    /// Annotate: strokes follow the finger EXACTLY (no smoothing lag), so ink
    /// bypasses the loop. Pause the loop so it can't fight the pen.
    func ink(phase: String, x: Double, y: Double) {
        stopLoop()
        view?.ink(phase: phase, nx: x, ny: y)
    }

    func clear() { view?.clearInk() }

    /// Audience countdown on the presentation display. `on:false` hides it and,
    /// when nothing else is showing, takes the whole overlay down with it.
    func setTimer(on: Bool, secs: Int, warn: Bool) {
        if on {
            guard resolveScreen() != nil else { return }
            ensureWindow()
            if let screen = resolveScreen() { retarget(to: screen) }
            view?.setTimer(on: true, secs: secs, warn: warn)
            show()
        } else {
            view?.setTimer(on: false, secs: 0, warn: false)
        }
    }

    /// Aiming: ease the REAL cursor toward this normalized point. Replaces the
    /// old `CGWarp` teleport — gliding the cursor (via posted `.mouseMoved`) is
    /// what kills the "jumps randomly" feel. See `setTarget`/`tick`.
    func cursor(x: Double, y: Double) { setTarget(CGPoint(x: x, y: y), cursor: true) }

    /// Update the smoothing target. On a FRESH (re)start: aiming seeds the render
    /// point from where the cursor REALLY is (so it glides from there, never
    /// teleports), while the overlay seeds at the target (it should appear AT the
    /// engage point). Every subsequent update eases toward the target.
    private func setTarget(_ n: CGPoint, cursor: Bool) {
        let fresh = (smoothTimer == nil)
        targetN = n
        drivingCursor = cursor
        if fresh {
            if cursor {
                if targetScreen == nil { targetScreen = resolveScreen() }
                renderN = currentCursorNormalized()
            } else {
                renderN = n
                view?.movePointer(nx: Double(n.x), ny: Double(n.y))   // overlay at the engage point
            }
        }
        startLoop()
    }

    /// The real cursor's current position as a normalized point on the target
    /// screen — the seed so aiming glides FROM the cursor, never teleports TO it.
    private func currentCursorNormalized() -> CGPoint {
        guard let screen = targetScreen ?? resolveScreen() else { return CGPoint(x: 0.5, y: 0.5) }
        let loc = CGEvent(source: nil)?.location ?? .zero   // CG global, top-left
        let f = screen.frame
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? f.height
        let cgTop = primaryH - f.maxY
        return CGPoint(x: min(max((loc.x - f.minX) / f.width, 0), 1),
                       y: min(max((loc.y - cgTop) / f.height, 0), 1))
    }

    private func startLoop() {
        guard smoothTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        smoothTimer = t
    }

    private func stopLoop() { smoothTimer?.cancel(); smoothTimer = nil }

    /// One easing step toward the target (~120 Hz). Settled frames are a no-op
    /// (the loop stays warm so the next move glides, not snaps).
    private func tick() {
        let dx = targetN.x - renderN.x, dy = targetN.y - renderN.y
        if abs(dx) < 0.0003, abs(dy) < 0.0003 { renderN = targetN; return }
        renderN.x += dx * smoothing
        renderN.y += dy * smoothing
        if drivingCursor { postCursor(renderN) }
        else { view?.movePointer(nx: Double(renderN.x), ny: Double(renderN.y)) }
    }

    /// Post an absolute `.mouseMoved` at a normalized point (smooth, jump-free).
    /// Normalized (top-left) → CG global (top-left): CG's origin is the top-left
    /// of the PRIMARY screen (the one at NS (0,0)); a secondary screen's CG top =
    /// primaryHeight − its NS maxY. Requires Accessibility (CGEvent posting) — the
    /// host already needs it for keyboard/trackpad; the overlay DRAWING stays
    /// permission-free.
    private func postCursor(_ n: CGPoint) {
        guard let screen = targetScreen ?? resolveScreen() else { return }
        targetScreen = screen
        let f = screen.frame
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? f.height
        let p = CGPoint(x: f.minX + n.x * f.width, y: (primaryH - f.maxY) + n.y * f.height)
        CGEvent(mouseEventSource: cursorSource, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cgSessionEventTap)
    }

    /// Full teardown: wipe ink, drop to "off", fade out. Called on `ovl.mode
    /// off` and on EVERY client teardown path in the Server (a dropped phone
    /// must never leave the Mac dimmed). Safe to call when already hidden.
    func reset() {
        stopLoop()
        view?.clearInk()
        view?.configure(mode: "off", rf: 0.12, dim: 0, color: .white)
        hide()
    }

    // MARK: Window lifecycle

    private func ensureWindow() {
        guard panel == nil else { return }
        let v = OverlayView(frame: .zero)
        v.wantsLayer = true
        // Borderless + non-activating so showing it never steals focus/Space
        // from the presentation app; click-through so it never eats a click.
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .screenSaver                 // float above fullscreen Keynote/PPT
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true            // never block the real cursor
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                .stationary, .ignoresCycle]
        p.contentView = v
        p.alphaValue = 0
        panel = p
        view = v
    }

    /// Move the window to cover `screen` if it isn't already.
    private func retarget(to screen: NSScreen) {
        guard let panel else { return }
        if targetScreen != screen || panel.frame != screen.frame {
            targetScreen = screen
            panel.setFrame(screen.frame, display: false)
            view?.frame = NSRect(origin: .zero, size: screen.frame.size)
            view?.layoutLayers()
        }
    }

    private func show() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        guard !visible else { return }
        visible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            // Only order out if a re-show didn't race us back to opaque.
            if panel?.alphaValue == 0 { panel?.orderOut(nil) }
        })
    }

    /// Screen under the cursor right now, falling back to main / first.
    private func resolveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// "RRGGBB" → NSColor; nil/invalid → the deck accent (cobalt).
    static func color(fromHex hex: String?) -> NSColor {
        guard let hex, hex.count == 6, let v = Int(hex, radix: 16) else {
            return NSColor(srgbRed: 0x3D/255.0, green: 0x5B/255.0, blue: 0xFF/255.0, alpha: 1)
        }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
    }
}

// MARK: - The drawing view

/// Layer-backed renderer for the four sub-modes. Coordinates arrive normalized
/// (0–1, origin top-left, y down) and are mapped to the view's bottom-left,
/// y-up layer space in `pt(_:_:)`. Non-flipped on purpose — the explicit flip
/// is unambiguous; a flipped layer-backed view's geometry is fiddly.
private final class OverlayView: NSView {
    private var mode = "off"
    private var radius: CGFloat = 80
    private var color: NSColor = .white
    /// Last pointer position in layer space; seeded to centre so the cutout
    /// doesn't pop in from a corner before the first `ovl.move`.
    private var last: CGPoint = .zero

    // Spotlight/square: a black dim layer revealed everywhere except a cutout
    // punched by an even-odd mask path.
    private let dimLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    // A colored glow ring stroked around the cutout boundary (the spotlight takes
    // the chosen color); a soft colored shadow gives the halo.
    private let ringLayer = CAShapeLayer()
    // Pointer = a digital laser: a colored core with a soft glow + white centre.
    private let dotLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    // Annotate: a container of finished/in-progress stroke layers + a live pen.
    /// Presentation blanking (§Presenter): an opaque full-bleed fill. Black is
    /// the primary "look at me, not the slide" control; white stands in for a
    /// whiteboard. Separate from dimLayer because dim is masked to a cutout.
    private let blankLayer = CALayer()
    /// Audience countdown drawn ON the presentation display (Q&A, exercises,
    /// breaks) — the room reads it, not just the presenter.
    private let timerLayer = CATextLayer()
    /// Quiet brand watermark, shown only while the screen is blanked — a blank
    /// projector with nothing on it looks broken, and a small mark says the
    /// blanking is deliberate. Bottom-left, low contrast on purpose: it must not
    /// compete with the presenter.
    private let markLayer = CALayer()
    private let markTile = CATextLayer()
    private let markWord = CATextLayer()
    private let inkLayer = CALayer()
    private var strokeLayer: CAShapeLayer?
    private var strokePath: CGMutablePath?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dimLayer)
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.mask = maskLayer
        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = NSColor.black.cgColor   // mask uses alpha; colour irrelevant
        dimLayer.isHidden = true

        ringLayer.isHidden = true
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineWidth = 3
        ringLayer.shadowOffset = .zero                // glow centered on the ring
        layer?.addSublayer(ringLayer)                 // above the dim, around the cutout

        layer?.addSublayer(inkLayer)
        blankLayer.isHidden = true
        blankLayer.zPosition = 50           // above dim/ink, below the timer
        layer?.addSublayer(blankLayer)
        markLayer.isHidden = true
        markLayer.zPosition = 55
        markTile.alignmentMode = .center
        markTile.string = "R"
        markTile.cornerRadius = 6
        markTile.masksToBounds = true
        markWord.string = "Remotype"
        markLayer.addSublayer(markTile)
        markLayer.addSublayer(markWord)
        layer?.addSublayer(markLayer)
        timerLayer.isHidden = true
        timerLayer.zPosition = 60           // legible even over a blanked screen
        timerLayer.alignmentMode = .center
        timerLayer.foregroundColor = NSColor.white.cgColor
        timerLayer.shadowColor = NSColor.black.cgColor
        timerLayer.shadowOpacity = 0.85
        timerLayer.shadowRadius = 18
        timerLayer.shadowOffset = .zero
        layer?.addSublayer(timerLayer)
        inkLayer.isHidden = true

        dotLayer.isHidden = true
        dotLayer.shadowOffset = .zero          // glow centered on the dot
        coreLayer.isHidden = true
        coreLayer.fillColor = NSColor.white.cgColor
        layer?.addSublayer(dotLayer)
        layer?.addSublayer(coreLayer)          // white hot centre on top
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var isFlipped: Bool { false }

    /// Normalized (top-left, y-down) → layer space (bottom-left, y-up).
    private func pt(_ nx: Double, _ ny: Double) -> CGPoint {
        CGPoint(x: CGFloat(nx) * bounds.width, y: (1 - CGFloat(ny)) * bounds.height)
    }

    /// Re-seat full-bleed layers after a frame/screen change.
    /// Show/hide the audience countdown. The PHONE owns the clock and pushes
    /// the remaining seconds — the host only renders. That keeps pause/resume
    /// and drift in one place instead of two clocks trying to agree.
    func setTimer(on: Bool, secs: Int, warn: Bool) {
        noAnim {
            timerLayer.isHidden = !on
            guard on else { return }
            let neg = secs < 0
            let a = abs(secs)
            let text = String(format: "%@%d:%02d", neg ? "-" : "", a / 60, a % 60)
            let size = max(64, min(bounds.height * 0.22, 320))
            timerLayer.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            timerLayer.fontSize = size
            timerLayer.string = text
            // On a WHITE blank the screen is white: white text is invisible and
            // even the red reads poorly, so the countdown flips to ink.
            let onWhite = (mode == "white")
            let base: NSColor = onWhite ? .black : .white
            let alarm: NSColor = onWhite ? NSColor(red: 0.72, green: 0, blue: 0, alpha: 1) : .systemRed
            timerLayer.foregroundColor = (warn || neg ? alarm : base).cgColor
            timerLayer.shadowColor = (onWhite ? NSColor.white : NSColor.black).cgColor
            timerLayer.contentsScale = window?.backingScaleFactor ?? 2
            layoutTimer()
        }
    }

    /// Bottom-left brand watermark: accent tile + wordmark, deliberately faint.
    private func layoutMark(onWhite: Bool) {
        let scale = window?.backingScaleFactor ?? 2
        let tile: CGFloat = max(22, bounds.height * 0.028)
        let pad: CGFloat = tile * 1.4
        markTile.frame = CGRect(x: pad, y: pad, width: tile, height: tile)
        markTile.backgroundColor = NSColor(srgbRed: 0.239, green: 0.357, blue: 1, alpha: 1).cgColor
        markTile.font = NSFont.systemFont(ofSize: tile * 0.5, weight: .heavy)
        markTile.fontSize = tile * 0.5
        markTile.foregroundColor = NSColor.white.cgColor
        markTile.contentsScale = scale
        markWord.font = NSFont.systemFont(ofSize: tile * 0.62, weight: .semibold)
        markWord.fontSize = tile * 0.62
        markWord.foregroundColor = (onWhite ? NSColor.black : NSColor.white).cgColor
        markWord.contentsScale = scale
        markWord.frame = CGRect(x: pad + tile + tile * 0.34,
                                y: pad + (tile - tile * 0.78) / 2,
                                width: tile * 6, height: tile * 0.78)
        // Faint: present, never the thing the room looks at.
        markLayer.opacity = onWhite ? 0.30 : 0.38
    }

    private func layoutTimer() {
        let h = timerLayer.fontSize * 1.25
        // Lower third: clear of slide titles, still readable from the back row.
        timerLayer.frame = CGRect(x: 0, y: bounds.height * 0.12, width: bounds.width, height: h)
    }

    func layoutLayers() {
        noAnim {
            dimLayer.frame = bounds
            inkLayer.frame = bounds
            blankLayer.frame = bounds
            markLayer.frame = bounds
            layoutTimer()
            if last == .zero { last = CGPoint(x: bounds.midX, y: bounds.midY) }
            redrawForMode()
        }
    }

    func configure(mode m: String, rf: Double, dim: Int, color c: NSColor) {
        mode = m
        color = c
        radius = max(8, CGFloat(rf) * min(bounds.width, bounds.height))
        if last == .zero { last = CGPoint(x: bounds.midX, y: bounds.midY) }
        noAnim {
            dimLayer.opacity = Float(dim) / 100.0
            // Per-mode layer visibility.
            let blank = (m == "black" || m == "white")
            blankLayer.isHidden = !blank
            markLayer.isHidden = !blank
            if blank { layoutMark(onWhite: m == "white") }
            if blank {
                blankLayer.frame = bounds
                blankLayer.backgroundColor = (m == "white" ? NSColor.white : NSColor.black).cgColor
            }
            let spot = (m == "spotlight" || m == "square")
            dimLayer.isHidden = !spot
            ringLayer.isHidden = !spot
            dotLayer.isHidden = (m != "pointer")
            coreLayer.isHidden = (m != "pointer")
            inkLayer.isHidden = (m != "annotate")
            if spot {
                ringLayer.strokeColor = color.cgColor
                ringLayer.shadowColor = color.cgColor   // colored halo around the cutout
                ringLayer.shadowRadius = 12
                ringLayer.shadowOpacity = 0.8
            }
            if m == "pointer" {
                dotLayer.fillColor = color.cgColor
                dotLayer.shadowColor = color.cgColor   // colored glow halo
                dotLayer.shadowRadius = 16
                dotLayer.shadowOpacity = 0.9
            }
            redrawForMode()
        }
    }

    func movePointer(nx: Double, ny: Double) {
        last = pt(nx, ny)
        noAnim { redrawForMode() }
    }

    // MARK: Annotate

    func ink(phase: String, nx: Double, ny: Double) {
        let p = pt(nx, ny)
        last = p
        noAnim {
            switch phase {
            case "down":
                let path = CGMutablePath()
                path.move(to: p)
                // A lone dot (down+up with no move) should still leave a mark:
                // seed a zero-length line so the round cap renders.
                path.addLine(to: p)
                strokePath = path
                let s = CAShapeLayer()
                s.strokeColor = color.cgColor
                s.fillColor = NSColor.clear.cgColor
                s.lineWidth = 5
                s.lineCap = .round
                s.lineJoin = .round
                s.path = path
                inkLayer.addSublayer(s)
                strokeLayer = s
            case "move":
                guard let path = strokePath, let s = strokeLayer else { return }
                path.addLine(to: p)
                s.path = path
            default: // "up"
                strokeLayer = nil
                strokePath = nil
            }
            updatePenDot(at: p, show: phase != "up")
        }
    }

    func clearInk() {
        noAnim {
            inkLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            strokeLayer = nil
            strokePath = nil
            penDot?.removeFromSuperlayer()
            penDot = nil
        }
    }

    /// A small live "pen tip" dot shown while drawing so the user sees where
    /// the ink will land.
    private var penDot: CAShapeLayer?
    private func updatePenDot(at p: CGPoint, show: Bool) {
        guard mode == "annotate" else { return }
        if !show { penDot?.removeFromSuperlayer(); penDot = nil; return }
        let r: CGFloat = 5
        let dot = penDot ?? {
            let d = CAShapeLayer()
            d.fillColor = color.withAlphaComponent(0.9).cgColor
            inkLayer.addSublayer(d)
            penDot = d
            return d
        }()
        dot.path = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r), transform: nil)
    }

    // MARK: Shared redraw

    private func redrawForMode() {
        switch mode {
        case "spotlight":
            maskLayer.frame = bounds
            let path = CGMutablePath()
            path.addRect(bounds)
            let cut = CGRect(x: last.x - radius, y: last.y - radius, width: 2*radius, height: 2*radius)
            path.addEllipse(in: cut)
            maskLayer.path = path      // even-odd → dim everywhere but the circle
            ringLayer.frame = bounds
            ringLayer.path = CGPath(ellipseIn: cut, transform: nil)   // colored edge follows the cutout
        case "square":
            maskLayer.frame = bounds
            let path = CGMutablePath()
            path.addRect(bounds)
            let side = radius * 1.6     // a square reads smaller than a circle of equal "radius"; widen it
            let cut = CGRect(x: last.x - side, y: last.y - side*0.62,
                             width: 2*side, height: 2*side*0.62)       // 16:10-ish window
            path.addRect(cut)
            maskLayer.path = path
            ringLayer.frame = bounds
            ringLayer.path = CGPath(rect: cut, transform: nil)
        case "pointer":
            // Laser-sized, not a blob: a small colored core (glow from the layer
            // shadow) + a white-hot centre on top.
            let r = max(7, radius * 0.16)
            dotLayer.path = CGPath(ellipseIn: CGRect(x: last.x - r, y: last.y - r,
                                                     width: 2*r, height: 2*r), transform: nil)
            let cr = max(3, r * 0.42)
            coreLayer.path = CGPath(ellipseIn: CGRect(x: last.x - cr, y: last.y - cr,
                                                      width: 2*cr, height: 2*cr), transform: nil)
        default:
            break
        }
    }

    /// Run layer mutations with implicit animations OFF — the difference
    /// between buttery pointer tracking and a laggy, easing-in cutout.
    private func noAnim(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
