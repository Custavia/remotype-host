import Foundation
import AppKit
import ApplicationServices
import CoreMedia
import CoreImage
import CoreGraphics
import ScreenCaptureKit

/// TV mode: a live, MAGNIFIED slice of the screen streamed to the
/// phone. The trick that makes a phone-sized panel useful — and cheap — is that
/// the host crops a SMALL region around the focus point (the cursor for v1) and
/// scales it to a fixed small output on the GPU via ScreenCaptureKit's
/// `sourceRect`, so only the slice is ever encoded. The phone just decodes and
/// blits; it never sees a full-screen frame.
///
/// Lifecycle mirrors the vitals stream in Server: started on `tv.sub`, stopped
/// on `tv.unsub` and EVERY connection teardown path. Frames are JPEG-encoded on
/// the capture queue and handed to the start-time `onFrame` closure; the Server
/// base64s and ships them pinned to the subscriber connection.
///
/// THREADING: every mutable field, the pan timer, the SCK frame callback, and
/// start/stop all run on the single serial [queue] — so there are no data races,
/// and an `epoch` makes the async `start` race-proof (a completion that lands
/// after a stop/restart is dropped, so a stream/timer can never outlive its
/// subscriber). The only thing the Server touches is start()/stop().
///
/// Permission: ScreenCaptureKit needs the Mac's Screen Recording grant — the
/// Server preflights it and answers `tv.err noperm` if it's missing, so this
/// controller is only started once the grant is present.
/// What the magnified lens follows. `cursor`/`caret`/`auto` crop a small region;
/// `full` shows the whole display scaled to fit (no magnification).
enum TVFollow: String {
    // `manual` is the lens steered by hand and is LEFT the moment the trackpad
    // moves (exitManualToCursor: the cursor "comes to you"). `off` is the user
    // saying "stop following anything": the lens freezes where it is and stays
    // frozen through trackpad moves and typing, until a follow mode is picked
    // again. Both crop around panCenter; only their exits differ.
    case auto, cursor, caret, full, manual, off
    init(wire: String?) { self = TVFollow(rawValue: wire ?? "") ?? .auto }
}

/// One instant of the lens's truth, as the phone needs to see it. Copied out under
/// a lock rather than read field-by-field: a torn 32-byte CGRect would warp the
/// cursor to a garbage point, which is a different class of harm from the benign
/// stale-Bool read `isManualFollow` documents below.
struct TVLens {
    var display: CGRect = .zero        // CG global, top-left, points
    var region: CGRect = .zero         // the sourceRect being streamed
    var zoom: Double = 0               // RESOLVED effective magnification, always > 0 once valid
    var nat = false                    // the 1:1 detent produced that zoom
    /// Panel pixels per captured pixel: outW / (region.width * backingScale).
    /// > 1 means the phone is drawing each Mac pixel more than once — blur when
    /// filtered, blocks when not. The phone picks its sampling from this.
    var mag: Double = 1
    var follow: TVFollow = .auto       // what the client asked for
    var resolved: TVFollow = .auto     // what "auto" actually became this instant
    var seq = 0                        // bumped ONLY when `region` changes
    var valid: Bool { region.width > 0 && region.height > 0 }
}

@available(macOS 12.3, *)
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {

    /// One serial queue owns ALL state: control (start/stop), the pan timer, and
    /// the SCK frame callback (it's the addStreamOutput sampleHandlerQueue too).
    private let queue = DispatchQueue(label: "remotype.tv")

    private var stream: SCStream?
    private var displayFrame: CGRect = .zero      // CG global, top-left origin, points
    private var outW = 360
    private var outH = 480
    /// 1:1 detent: zoom chosen so the captured region's PHYSICAL
    /// pixels equal the output buffer — no resampling anywhere in the chain.
    /// Armed by the wire sentinel `tv.zoom z:0` (and `tv.sub z:0`); any explicit
    /// zoom value disarms it. While armed, JPEG quality rises too: at 1:1 the
    /// bandwidth is already bounded by the PHONE's pixels, so quantization is
    /// the only softness left — spend the bits (owner call, 2026-08-22).
    private var nativeDetent = false
    /// Consecutive pan ticks with the cursor on a different display (cross-
    /// display follow debounce).
    private var offDisplayTicks = 0
    /// The captured display's backing scale (physical px per point), resolved at
    /// config time; 2.0 on every retina Mac.
    private var backingScale = 2.0
    private var zoom = 2.0
    private var follow: TVFollow = .auto { didSet { isManualFollow = (follow == .manual) } }
    /// Mirrors `follow == .manual`, read OFF the queue by the Server to decide whether
    /// a trackpad move should warp the cursor into the framed region. A benign
    /// cross-thread read — a stale value at worst misses/duplicates a single warp.
    private(set) var isManualFollow = false
    private var panCenter: CGPoint = .zero         // manual-pan crop center (display-local, top-left points)
    private var lastRegion: CGRect = .zero         // last applied sourceRect (pan only updates on change)
    private var stateTicks = 0                     // pan-tick counter, throttles the still-lens tv.state
    // Frame-flow bookkeeping, all touched only on `queue` (the sample handler
    // runs there too, so no lock). See the stall watchdog in the pan tick.
    private var lastConfigAt: CFAbsoluteTime = 0   // last updateConfiguration
    private var lastFrameAt: CFAbsoluteTime = 0    // last COMPLETE frame delivered
    private var lastRestartAt: CFAbsoluteTime = 0  // watchdog cooldown
    /// Floor between reconfigures. ZERO — the pan tick reconfigures as it always
    /// has. A throttle here looked like the fix for the reported freeze, but an
    /// A/B against the old build could not support it: frame rate in cursor-follow
    /// swings between 5 and 25 fps run to run purely with whether the thing
    /// CHANGING on screen happens to sit inside the lens, which swamps the effect
    /// of any reconfigure rate. Left as a named constant because the mechanism is
    /// still plausible and the next person will reach for it.
    private static let configInterval: CFAbsoluteTime = 0
    /// The lens snapshot the Server reads to answer `tv.point` and to push `tv.state`.
    /// Guarded by `lensLock`, NOT by `queue`: the warp must happen INLINE on .main in
    /// wire order so the `mc` that follows a tap clicks where the finger landed, and a
    /// queue.sync from .main would deadlock against the frame path.
    private let lensLock = NSLock()
    private var _lens = TVLens()
    private var lensSeq = 0
    /// The last 8 (seq, lens) pairs. A finger touches the frame it can SEE, which the
    /// host may already have moved on from — mapping that touch against the current
    /// rect is wrong by exactly one lens hop while the pointer is moving. Small ring:
    /// 8 hops at 30 Hz is a quarter second, far longer than a round trip.
    private var lensRing: [(seq: Int, lens: TVLens)] = []

    /// A copy of the current lens. Safe from any thread.
    var lens: TVLens {
        lensLock.lock(); defer { lensLock.unlock() }
        return _lens
    }

    /// The lens for a given sequence, or the current one when `seq` is 0 (the phone
    /// has not rendered a frame yet) or too old to still be held.
    func lens(forSeq seq: Int) -> TVLens {
        lensLock.lock(); defer { lensLock.unlock() }
        if seq > 0, let hit = lensRing.last(where: { $0.seq == seq }) { return hit.lens }
        return _lens
    }

    /// Publish a new lens instant. Bumps the sequence only when the RECT moved, so
    /// `s` stays a rect identity rather than a tick counter.
    private func publishLensLocked(regionChanged: Bool) {
        var l = TVLens()
        l.display = displayFrame
        l.region = lastRegion
        l.nat = nativeDetent
        l.follow = follow
        l.resolved = (follow == .auto) ? (caretLocal() != nil ? .caret : .cursor) : follow
        // The honest magnification of the pixels on screen: the base field of view
        // divided by the width actually being cropped. Derived, never the stored
        // request — `full` ignores zoom, regionAround clamps to the display edge, and
        // the detent is resolved from geometry, so the stored number is often a lie.
        l.zoom = lastRegion.width > 0 ? Self.baseFOV / lastRegion.width : 0
        l.mag = magnificationLocked()
        lensLock.lock()
        if regionChanged || _lens.region != lastRegion { lensSeq &+= 1 }
        l.seq = lensSeq
        _lens = l
        lensRing.append((lensSeq, l))
        if lensRing.count > 8 { lensRing.removeFirst(lensRing.count - 8) }
        lensLock.unlock()
        onState?(l, cursorInLens(l))
    }

    /// The cursor as a fraction of the lens rect, or nil when it is outside it or
    /// unreadable. Absence, never a lie — a (0,0) default would park the phone's
    /// cursor puck in the corner, indistinguishable from a real pointer there.
    private func cursorInLens(_ l: TVLens) -> CGPoint? {
        guard l.valid else { return nil }
        let g = cursorGlobal()
        let x = (g.x - l.region.minX) / l.region.width
        let y = (g.y - l.region.minY) / l.region.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Fired whenever the lens's truth changes (on `queue`). The Server turns this
    /// into `tv.state`. A controller-lifetime var so it survives the capture restart
    /// a cross-display follow performs.
    var onState: ((TVLens, CGPoint?) -> Void)?

    /// Warp the real cursor to a normalized point inside the lens for `seq`.
    /// Returns false when there is no lens yet — a tap during startup must be
    /// DROPPED, because warping to the display origin is worse than doing nothing.
    @discardableResult
    func pointAt(x: Double, y: Double, seq: Int) -> Bool {
        let l = lens(forSeq: seq)
        guard l.valid else { return false }
        let gx = l.region.minX + min(max(x, 0), 1) * l.region.width
        let gy = l.region.minY + min(max(y, 0), 1) * l.region.height
        // The ovl.cursor family: a warp, not a posted event, so no Accessibility
        // grant is needed for the pointing itself (the click that follows still is).
        CGWarpMouseCursorPosition(CGPoint(x: gx, y: gy))
        CGAssociateMouseAndMouseCursorPosition(1)
        // Pin the lens. In cursor/caret follow the rect re-centres on the cursor
        // within a tick, so warping would move the lens under the finger and the
        // next sample would land somewhere else — the feedback loop this verb would
        // otherwise create. Pinning stops it at the source.
        queue.async { [weak self] in
            guard let self else { return }
            if self.follow != .manual {
                self.panCenter = CGPoint(x: self.lastRegion.midX, y: self.lastRegion.midY)
                self.follow = .manual
            }
            self.applyRegionNowLocked()
        }
        return true
    }
    private var frameHandler: ((Data) -> Void)?
    /// Cast DIRECT path: when set, the raw CVImageBuffer is handed straight to the
    /// VideoToolbox H.264 encoder and the JPEG path is skipped entirely. Mutually
    /// exclusive with frameHandler (browser/TV use JPEG; cast uses raw).
    private var sampleHandler: ((CMSampleBuffer) -> Void)?
    /// Fired (on `queue`) when a capture start fails after the subscription was
    /// accepted — shareable-content fetch, addStreamOutput, or startCapture. The
    /// Server forwards this as `tv.err capture` so the phone shows an actionable
    /// error instead of the eternal "Showing your computer screen…" placeholder.
    var onStartFailed: (() -> Void)?
    /// System-wide AX element for caret-follow; messaging timeout caps how long a
    /// wedged app can stall a read (the read runs off .main, on `queue`).
    private let axSystem: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        // 0.05 s was too tight: Electron apps answer AX slowly, so every query
        // (even finding the app) timed out → "no focused element". 0.25 s is the
        // worst case for a wedged app, on a background queue, so it can't stall input.
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }()
    /// Bumped on every start/stop; an async start's completion bails if it no
    /// longer matches — so a stream is never created after a stop/restart.
    private var epoch = 0
    private var panTimer: DispatchSourceTimer?

    // Reused, Metal-backed — building a CIContext per frame is the classic perf
    // trap. cacheIntermediates off keeps memory flat for a streaming workload.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let jpegColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Field-of-view in POINTS at zoom 1 (the captured region's width). Smaller
    /// region = more magnification. 360 pt @ 1x → 180 pt @ 2x → 120 pt @ 3x.
    private static let baseFOV: Double = 360

    // MARK: Start / stop  (public entry — hop onto `queue`)

    func start(w: Int, h: Int, zoom: Double, follow: TVFollow,
               onFrame: ((Data) -> Void)? = nil,
               onSample: ((CMSampleBuffer) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.epoch += 1
            let myEpoch = self.epoch
            self.outW = max(120, w)
            self.outH = max(120, h)
            self.nativeDetent = zoom <= 0
            // 1.0 is a PLACEHOLDER for the detent, not its zoom: the real value
            // is baseFOV * scale / outW, which needs geometry we do not have yet.
            // resolveNativeZoomLocked() below replaces it as soon as backingScale
            // is known.
            self.zoom = self.nativeDetent ? 1.0 : min(max(zoom, 0.4), 8.0)
            self.follow = follow
            self.frameHandler = onFrame
            self.sampleHandler = onSample
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
                [weak self] content, error in
                self?.queue.async {
                    guard let self else { return }
                    // Superseded by a stop/restart while the fetch was in flight —
                    // drop it, or we'd orphan a stream the subscriber no longer wants.
                    guard myEpoch == self.epoch else { return }
                    guard let content, error == nil,
                          let display = self.displayUnderCursor(content) ?? content.displays.first else {
                        NSLog("RemotypeHost: TV shareable content failed: content=\(content != nil) displays=\(content?.displays.count ?? -1) error=\(String(describing: error))")
                        self.onStartFailed?()
                        return
                    }
                    self.displayFrame = display.frame
                    // Backing scale for the 1:1 detent: physical px / points.
                    if let mode = CGDisplayCopyDisplayMode(display.displayID),
                       display.frame.width > 0 {
                        self.backingScale = Double(mode.pixelWidth) / Double(display.frame.width)
                    }
                    self.resolveNativeZoomLocked()
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let region = self.focusRegion()
                    self.lastRegion = region
                    let stream = SCStream(filter: filter,
                                          configuration: self.makeConfig(sourceRect: region),
                                          delegate: self)
                    do {
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                        stream.startCapture { [weak self] err in
                            if let err {
                                NSLog("RemotypeHost: TV startCapture failed: \(err)")
                                self?.queue.async { self?.onStartFailed?() }
                            }
                        }
                        self.stream = stream
                        self.startPanLocked()
                    } catch {
                        NSLog("RemotypeHost: TV addStreamOutput failed: \(error)")
                        self.onStartFailed?()
                    }
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    /// Change what the lens follows, live (no stream restart). Applies IMMEDIATELY
    /// if the stream is up — not on the next pan tick — so the very first switch in
    /// a fresh TV session takes effect (the earlier bug: relying on the pan tick
    /// could miss the change while the stream was still starting).
    func setFollow(_ mode: TVFollow) {
        queue.async { [weak self] in
            guard let self else { return }
            // Seed the manual centre the way setPan does. Without this, a client
            // picking "manual" directly — which it can, now that tv.state lets it SEE
            // the mode — jumps the lens to whatever stale panCenter was lying around.
            let pinned: Set<TVFollow> = [.manual, .off]
            if pinned.contains(mode), !pinned.contains(self.follow) {
                self.panCenter = CGPoint(x: self.lastRegion.midX, y: self.lastRegion.midY)
            }
            self.follow = mode
            self.applyRegionNowLocked()
            self.publishLensLocked(regionChanged: true)
        }
    }

    /// Change the magnification, live. Allows zooming OUT below 1× (a wider field
    /// of view than the base) down to 0.4×.
    /// Resolve the 1:1 zoom once geometry is known: region points x scale ==
    /// output px  =>  zoom = baseFOV * scale / outW. Called wherever zoom is read
    /// while the detent is armed.
    private func resolveNativeZoomLocked() {
        guard nativeDetent, backingScale > 0 else { return }
        zoom = min(max(Self.baseFOV * backingScale / Double(outW), 0.2), 8.0)
    }

    func setZoom(_ z: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            // z <= 0 is the wire sentinel for the 1:1 detent; any real value
            // disarms it and behaves as before.
            self.nativeDetent = z <= 0
            if self.nativeDetent { self.resolveNativeZoomLocked() }
            // 0.2, not 0.4: the phone's sliders and pinch path now span 0.2–8.0,
            // and a floor the client can ask below is a thumb that snaps back.
            else { self.zoom = min(max(z, 0.2), 8.0) }
            self.applyRegionNowLocked()
            self.publishLensLocked(regionChanged: true)
        }
    }

    /// Manual pan (steer the lens by hand). [dx]/[dy] are normalized display-fraction
    /// deltas. Entering manual captures the CURRENT region centre first so there's no
    /// jump, then stops cursor/caret-following until a follow mode is re-picked. The
    /// phone sends these as a coalesced realtime stream while a finger drags.
    func setPan(dx: Double, dy: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            // A drag while OFF stays off: the user froze the lens and is now
            // nudging it. Only a follow mode enters manual, whose one difference
            // is that the next trackpad move hands the lens back to the cursor.
            if self.follow != .manual, self.follow != .off {
                self.panCenter = CGPoint(x: self.lastRegion.midX, y: self.lastRegion.midY)
                self.follow = .manual
            }
            self.panCenter.x = min(max(self.panCenter.x + dx * self.displayFrame.width, 0), self.displayFrame.width)
            self.panCenter.y = min(max(self.panCenter.y + dy * self.displayFrame.height, 0), self.displayFrame.height)
            defer { self.publishLensLocked(regionChanged: true) }
            // Do NOT updateConfiguration per pan event — the 30 Hz pan tick already
            // applies panCenter (.manual → regionAround(panCenter)). Reconfiguring
            // SCStream on every event of a fast drag overwhelms it and the capture
            // stops delivering frames (the picture freezes while input keeps flowing).
        }
    }

    /// A trackpad move arrived while manually panned: warp the REAL cursor to the
    /// centre of the framed region and start following it. So after you pan to look
    /// at something, the cursor "comes to you" (the point of panning) instead of the
    /// view snapping back to wherever the cursor used to be. One-shot: it leaves
    /// manual, so subsequent moves are ordinary relative cursor-follow.
    func exitManualToCursor() {
        queue.async { [weak self] in
            guard let self, self.follow == .manual else { return }
            let global = CGPoint(x: self.displayFrame.minX + self.panCenter.x,
                                 y: self.displayFrame.minY + self.panCenter.y)
            CGWarpMouseCursorPosition(global)
            // Clear the brief post-warp event suppression so the very next trackpad
            // delta moves the cursor immediately.
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            self.follow = .cursor
            self.applyRegionNowLocked()
        }
    }

    /// Panel pixels per captured pixel for the region being streamed. On [queue].
    private func magnificationLocked() -> Double {
        guard lastRegion.width > 0, backingScale > 0 else { return 1 }
        return Double(outW) / (lastRegion.width * backingScale)
    }

    /// Recompute + push the sourceRect right now if a stream exists; otherwise
    /// zero lastRegion so the start completion / next pan tick applies it. On [queue].
    private func applyRegionNowLocked() {
        guard let stream else { lastRegion = .zero; return }
        let r = focusRegion()
        lastRegion = r
        stream.updateConfiguration(panConfig(sourceRect: r)) { _ in }
    }

    /// MUST run on [queue]. Bumps the epoch so any in-flight start's completion
    /// is dropped, then tears the stream + timer + handler down.
    private func stopLocked() {
        epoch += 1
        panTimer?.cancel()
        panTimer = nil
        if let stream { try? stream.removeStreamOutput(self, type: .screen) }
        stream?.stopCapture { _ in }
        stream = nil
        frameHandler = nil
        sampleHandler = nil
        lastRegion = .zero
        // The cached pan config dies WITH the stream. It carries width/height,
        // and a fresh start() may have a new pair — a rotated phone, a dock
        // raised — while the cache still held the old one. The first pan tick
        // after such a start then pushed the OLD output size with the NEW
        // sourceRect: scalesToFit fitted a landscape slice into a portrait
        // canvas, the phone fitted that canvas into its glass, and the picture
        // sat tiny in the middle of black. Only a display-switch restart used to
        // clear it, which is why every other resubscribe showed the symptom.
        liveConfig = nil
    }

    // MARK: Pan-to-follow — runs on [queue]

    /// A 20 Hz tick that recomputes the crop per the follow mode. Only calls
    /// updateConfiguration when the region actually changed — a still cursor (or
    /// full-screen mode, whose region is constant) is silent.
    private func startPanLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self, let stream = self.stream else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // Stall watchdog. A quiet screen legitimately produces NO frames, so
            // silence alone means nothing — but silence right after we retargeted
            // the stream means the stream itself has wedged (SCK stops delivering
            // and reports no error). Restart it rather than leave a frozen picture
            // that only an off/on cycle recovers.
            if self.frameHandler != nil || self.sampleHandler != nil,
               now - self.lastConfigAt < 2.0, now - self.lastFrameAt > 2.0,
               now - self.lastRestartAt > 5.0 {
                self.lastRestartAt = now
                HostLog.write("tv: no frames for 2s while the lens was moving — restarting capture")
                self.restartOnCursorDisplayLocked()
                return
            }
            // Cross-display follow: when the lens tracks the cursor and the
            // cursor has moved to ANOTHER display, restart the capture on that
            // display (an SCStream is bound to one display; updateConfiguration
            // can't retarget it). Debounced to ~0.4 s so a pointer skimming the
            // seam doesn't thrash stream restarts.
            if self.follow == .cursor || self.follow == .auto || self.follow == .caret {
                let c = self.cursorGlobal()
                if !self.displayFrame.contains(c), self.displayFrame.width > 0 {
                    self.offDisplayTicks += 1
                    if self.offDisplayTicks >= 12 {   // ~0.4 s at 30 Hz
                        self.offDisplayTicks = 0
                        self.restartOnCursorDisplayLocked()
                        return
                    }
                } else {
                    self.offDisplayTicks = 0
                }
            }
            let r = self.focusRegion()
            let moved = !(abs(r.minX - self.lastRegion.minX) < 1 && abs(r.minY - self.lastRegion.minY) < 1
                && abs(r.width - self.lastRegion.width) < 1 && abs(r.height - self.lastRegion.height) < 1)
            if !moved {
                // The lens is still. Keep the cursor honest at ~10 Hz and beat once a
                // second, so a client that joined mid-stream converges and can tell a
                // live host from a silent one. Both are far below frame rate.
                self.stateTicks &+= 1
                if self.stateTicks % 3 == 0 { self.publishLensLocked(regionChanged: false) }
                return
            }
            // Throttled: if this tick is too soon after the last reconfigure, leave
            // `lastRegion` alone and take the move on the next one, ~33 ms later.
            guard now - self.lastConfigAt >= Self.configInterval else { return }
            self.stateTicks = 0
            self.lastRegion = r
            self.lastConfigAt = now
            self.publishLensLocked(regionChanged: true)
            stream.updateConfiguration(self.panConfig(sourceRect: r)) { _ in }
        }
        timer.resume()
        panTimer = timer
    }

    // MARK: Geometry (all CG global, TOP-LEFT origin, points — same space as
    // CGEvent.location, SCDisplay.frame, and AX bounds, so NO AppKit flip).

    /// The sourceRect for the current follow mode.
    private func focusRegion() -> CGRect {
        switch follow {
        case .full:
            // Whole display, scaled to the output — no magnification.
            return CGRect(origin: .zero, size: displayFrame.size)
        case .manual, .off:
            // Steered by hand (tv.pan) or switched off — fixed on panCenter, no
            // auto-follow.
            return regionAround(panCenter)
        case .cursor:
            return regionAround(cursorLocal())
        case .caret, .auto:
            // Follow the text caret if there is one (you're typing), biased so the
            // caret sits ~70% across — you see what you've typed (to its left) with
            // headroom ahead. No caret → the cursor, centered.
            if let caret = caretLocal() {
                return regionAround(caret, biasX: 0.70)
            }
            return regionAround(cursorLocal())
        }
    }

    /// A magnified region around a display-local point, aspect-matched to the
    /// output and clamped to the display edges. [biasX] is where the point sits
    /// horizontally in the region (0.5 = centered; >0.5 leaves more room to its
    /// LEFT — used for the caret so prior text stays visible).
    private func regionAround(_ p: CGPoint, biasX: Double = 0.5) -> CGRect {
        // Deep zoom-out (z down to 0.4) can ask for a region wider than the
        // display; cap to the display so the sourceRect stays valid — beyond
        // that, "full" mode is the whole screen anyway.
        var regionW = min(Self.baseFOV / zoom, displayFrame.width)
        var regionH = regionW * Double(outH) / Double(outW)
        // Clamp BOTH axes, preserving the aspect.
        //
        // Only the width used to be capped, so a tall request — which is what a
        // phone asks for once the lens is cut to the panel rather than to a fixed
        // 8:5 — produced a region taller than the display. The sourceRect then got
        // clipped somewhere below us and the frame came back a DIFFERENT SHAPE to
        // the one asked for. That is worse than it sounds: the phone sizes its
        // glass from the frame's aspect, so the picture silently collapsed to a
        // narrow strip, and it looked like the panel resizing itself at random.
        //
        // Scaling both axes by the same factor keeps the contract the client
        // depends on — the frame always has the aspect that was requested — and
        // costs nothing when the region already fits.
        if regionH > displayFrame.height {
            let k = displayFrame.height / regionH
            regionH = displayFrame.height
            regionW *= k
        }
        var ox = p.x - regionW * biasX
        var oy = p.y - regionH / 2
        ox = min(max(ox, 0), max(0, displayFrame.width - regionW))
        oy = min(max(oy, 0), max(0, displayFrame.height - regionH))
        return CGRect(x: ox, y: oy, width: regionW, height: regionH)
    }

    /// Tear down and re-start the capture on whichever display now holds the
    /// cursor. start() re-resolves displayUnderCursor, backing scale, and the
    /// native detent; the brief re-config flash is the honest cost of moving a
    /// hardware stream between displays.
    private func restartOnCursorDisplayLocked() {
        // A restart is a fresh feed: don't let the watchdog judge the new stream on
        // the old one's clocks and immediately restart it again.
        lastFrameAt = CFAbsoluteTimeGetCurrent()
        lastConfigAt = 0
        liveConfig = nil
        let w = outW, h = outH
        let z = nativeDetent ? 0 : zoom
        let f = follow
        let onFrame = frameHandler
        let onSample = sampleHandler
        start(w: w, h: h, zoom: z, follow: f, onFrame: onFrame, onSample: onSample)
    }

    private func cursorGlobal() -> CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: displayFrame.midX, y: displayFrame.midY)
    }

    /// Cursor in the captured display's local top-left points.
    private func cursorLocal() -> CGPoint {
        let c = cursorGlobal()
        return CGPoint(x: c.x - displayFrame.minX, y: c.y - displayFrame.minY)
    }

    /// Last caret-detection source, logged once when it changes — so a test
    /// recording + the host log tell us exactly why caret-follow did/didn't work.
    private var lastCaretSource = ""
    private func noteCaretSource(_ s: String) {
        guard s != lastCaretSource else { return }
        lastCaretSource = s
        HostLog.write("tv caret source: \(s)")
    }

    /// The currently focused UI element (system-wide), or nil. We intentionally
    /// do NOT force-enable Chromium's accessibility tree (AXManualAccessibility):
    /// it flips Electron apps into "Screen Reader Optimized" mode — degrading the
    /// user's editor (word-wrap, suggestions, rendering) — and even then Chromium
    /// only reports whole-line bounds for a collapsed caret, which we can't use.
    /// So native apps get precise caret-follow; Electron/web fall back to cursor.
    private func focusedElement() -> AXUIElement? {
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axSystem, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Caret via the AXTextMarker API — how WebKit/Chromium expose text geometry.
    /// Best-effort: returns nil if the app won't answer, OR if it answers with the
    /// whole LINE/FIELD box instead of a real insertion point (Chromium does this
    /// for a collapsed caret — a wide rect that can't track typing). Callers then
    /// fall back to cursor-follow.
    private func caretViaTextMarker(_ element: AXUIElement) -> CGPoint? {
        var markerRange: AnyObject?
        guard AXUIElementCopyAttributeValue(
                element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let mr = markerRange else { return nil }
        var boundsVal: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, mr as CFTypeRef, &boundsVal) == .success,
              let bv = boundsVal, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        // Reject a whole-line / whole-field box: a real insertion point is a thin
        // sliver (a collapsed caret is ~0–2 pt wide; a single glyph a few pt).
        // Chromium hands back the entire line's width for a collapsed caret — bail
        // so we fall back to the cursor instead of pinning to the line's edge.
        guard rect.width <= 30 else { return nil }
        // Chromium / WebKit return this rect in APPKIT screen space (bottom-left
        // origin) — unlike the native kAXBoundsForRange path (CG top-left). Flip Y
        // about the primary-display height so it shares the cursor's space.
        let primaryH = CGDisplayBounds(CGMainDisplayID()).height
        let cgMidY = primaryH - rect.midY
        // Collapsed at the caret → maxX is the insertion point (right edge).
        return CGPoint(x: rect.maxX - displayFrame.minX, y: cgMidY - displayFrame.minY)
    }

    /// Screen bounds (top-left points) of a text range on [element], or nil.
    private func boundsForRange(_ element: AXUIElement, _ location: Int, _ length: Int) -> CGRect? {
        guard location >= 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsVal: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsVal) == .success,
              let bv = boundsVal, CFGetTypeID(bv) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The text-caret position in display-local points, or nil if the focused
    /// element doesn't expose a PRECISE insertion point — in which case the caller
    /// falls back to cursor-follow. The caret moves as you type, so we read the
    /// bounds of a real CHARACTER next to it (a zero-length range often returns an
    /// empty rect). Char-AT-caret gives its left edge; at end-of-text, char-BEFORE
    /// gives its right edge. Works on native AppKit apps; Electron/web that only
    /// report a whole-line box resolve to nil → cursor-follow.
    private func caretLocal() -> CGPoint? {
        guard let element = focusedElement()
        else { noteCaretSource("none"); return nil }

        // 1. Native text (kAXBoundsForRange): read a real CHARACTER next to the caret.
        var rangeVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success,
           let rv = rangeVal, CFGetTypeID(rv) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &range) {
                let loc = range.location
                if let r = boundsForRange(element, loc, 1), r.height > 0 {
                    noteCaretSource("char-at"); return CGPoint(x: r.minX - displayFrame.minX, y: r.midY - displayFrame.minY)
                }
                if loc > 0, let r = boundsForRange(element, loc - 1, 1), r.height > 0 {
                    noteCaretSource("char-before"); return CGPoint(x: r.maxX - displayFrame.minX, y: r.midY - displayFrame.minY)
                }
                if let r = boundsForRange(element, loc, 0), r.height > 0 {
                    noteCaretSource("range-collapsed"); return CGPoint(x: r.midX - displayFrame.minX, y: r.midY - displayFrame.minY)
                }
            }
        }

        // 2. Web/Electron: AXTextMarker — accepted only when it yields a precise
        //    caret (caretViaTextMarker rejects whole-line boxes).
        if let p = caretViaTextMarker(element) { noteCaretSource("text-marker"); return p }

        // No precise caret here → caller uses cursor-follow.
        noteCaretSource("none (cursor fallback)")
        return nil
    }

    private func displayUnderCursor(_ content: SCShareableContent) -> SCDisplay? {
        let c = CGEvent(source: nil)?.location ?? .zero
        return content.displays.first { $0.frame.contains(c) }
    }

    /// Reused for pan updates instead of allocating a fresh SCStreamConfiguration
    /// per reconfigure — same resulting configuration, one less allocation on a
    /// path that can run 30x a second.
    private var liveConfig: SCStreamConfiguration?

    private func panConfig(sourceRect: CGRect) -> SCStreamConfiguration {
        // Reuse only while the cache still describes the CURRENT output. The
        // stop path clears it; this guard is for any future path that changes
        // outW/outH without going through stop, so a stale size can never again
        // reach the stream from here.
        if let c = liveConfig, c.width == outW, c.height == outH {
            c.sourceRect = sourceRect; return c
        }
        let c = makeConfig(sourceRect: sourceRect); liveConfig = c; return c
    }

    private func makeConfig(sourceRect: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = outW
        config.height = outH
        config.sourceRect = sourceRect
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // 30 fps cap (smooth; LAN bandwidth is ample)
        config.showsCursor = true        // the lens centers on the cursor — show it
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        return config
    }

    // MARK: Frame delivery (on [queue])

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only ship complete frames — SCK also emits .idle/.blank/.suspended status.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete
        else { return }

        // Cast DIRECT: hand the raw frame to the H.264 encoder, skip JPEG entirely.
        if let sampleHandler {
            lastFrameAt = CFAbsoluteTimeGetCurrent()
            sampleHandler(sampleBuffer)
            return
        }

        lastFrameAt = CFAbsoluteTimeGetCurrent()
        guard let pixelBuffer = sampleBuffer.imageBuffer, let handler = frameHandler else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        // 0.55 balances Wi-Fi cost for the magnified lens; the 1:1 detent runs
        // at 0.85 — there, geometry is already pixel-exact and quantization is
        // the only remaining softness on glyph edges.
        // Quality rises with magnification. The more each captured pixel is
        // stretched on the phone, the more a JPEG block shows, and the fewer
        // real pixels there are to send — so the bytes are cheap exactly when
        // they help. 0.55 at 1:1 or below, 0.85 by 3x.
        let q = nativeDetent ? 0.85 : min(0.85, max(0.55, 0.55 + 0.15 * (magnificationLocked() - 1)))
        let options: [CIImageRepresentationOption: Any] =
            [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): q]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: jpegColorSpace, options: options)
        else { return }
        handler(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("RemotypeHost: TV stream stopped: \(error)")
        // It used to stop there — the picture then stayed frozen on the phone for
        // the rest of the session with no error surfaced, because as far as the
        // subscription was concerned everything was still running. Come back up if
        // a subscriber is still listening.
        queue.async { [weak self] in
            guard let self, self.stream === stream,
                  self.frameHandler != nil || self.sampleHandler != nil else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastRestartAt > 5.0 else { return }
            self.lastRestartAt = now
            HostLog.write("tv: capture stopped by the system — restarting")
            self.restartOnCursorDisplayLocked()
        }
    }
}
