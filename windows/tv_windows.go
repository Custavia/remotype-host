//go:build windows

// TV / screen-mirror capture for the Windows host — the phone's "TV mode" shows
// a magnified live view of the computer's screen. The macOS host does this with
// ScreenCaptureKit; here we GDI-StretchBlt a cursor-centered lens region of the
// primary display into a small DIB, JPEG-encode it, and stream base64 `tv.frame`s
// at 30 fps over the same connection — matching mac-companion/Sources/Capture.swift
// (baseFOV 360, zoom, follow, pan) and Server.swift's tv.frame wire format.
//
// Screen capture needs no OS permission on Windows (unlike macOS Screen Recording),
// so there is no `tv.err noperm` path — only a `tv.err capture` if GDI setup fails.
package main

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/jpeg"
	"math"
	"runtime"
	"sync"
	"time"
	"unsafe"
)

// Screen-capture GDI/user32 procs. The DC/DIB/bitmap procs, srcCopy, halftoneMode
// and procSetStretchBltMode are shared from overlay_windows.go / about_windows.go
// (same package + build tag); only these two are new here.
var (
	procStretchBlt     = gdi32.NewProc("StretchBlt")
	procGetDeviceCaps  = gdi32.NewProc("GetDeviceCaps")
	procGetCursorPos  = user32o.NewProc("GetCursorPos")
	procGetCursorInfo = user32o.NewProc("GetCursorInfo")
	procGetIconInfo   = user32o.NewProc("GetIconInfo")
	procDrawIconEx    = user32o.NewProc("DrawIconEx")
)

const (
	cursorShowing  = 0x0001
	diNormal       = 0x0003
	cursorBaseSize = 32 // logical cursor size (DPI-unaware); scaled to the output
	logPixelsX     = 88 // GetDeviceCaps index: horizontal DPI of the display
	colorOnColor   = 3  // StretchBlt mode: fast (drop rows/cols) vs halftoneMode's slow area-average
)

// CURSORINFO / ICONINFO — for compositing the mouse cursor into the frame (GDI
// BitBlt of the screen does NOT include the hardware cursor, unlike macOS SCK).
type cursorInfo struct {
	cbSize      uint32
	flags       uint32
	hCursor     uintptr
	ptScreenPos pointL
}
type iconInfo struct {
	fIcon    int32
	xHotspot uint32
	yHotspot uint32
	hbmMask  uintptr
	hbmColor uintptr
}

const (
	// Captured-region width at zoom 1, in POINTS — matches Capture.swift's
	// baseFOV, which is in points because CGDisplayBounds is. On Windows we work
	// in physical pixels, so this is scaled by the display factor at its use
	// site (see fovPx): without that, declaring DPI awareness silently made the
	// lens 1.5x more magnified on a 150% display than the same zoom on a Mac.
	tvBaseFOV = 360.0
	tvFPS         = 30    // matches the mac host's 30 fps stream (user-requested)
	tvJPEGQuality = 55    // matches the mac host (0.55)
	// At (or near) 1:1 the phone is painting one source pixel per screen pixel
	// and JPEG quantisation — not resolution — becomes the crispness ceiling, so
	// spend the bytes. Mirrors the mac host's nativeDetent ? 0.85 : 0.55.
	tvJPEGQualityNative = 85
	// Below this downscale factor nearest-neighbour is indistinguishable and
	// much cheaper; above it, dropping rows/columns visibly shreds text, so pay
	// for GDI's area-averaging instead.
	tvHalftoneBelowScale = 0.8
	tvMinDim      = 64
	tvMaxDim      = 1600 // guard the light-PC encoder against an oversized output
)

// tvSupported reports whether this host can stream its screen (advertised as
// `tv:1` in the hi handshake). Always true on Windows.
func tvSupported() bool { return true }

// tvSession owns one screen-mirror stream for a connection: a capture goroutine
// grabbing a lens region at tvFPS and shipping JPEG `tv.frame`s. The lens
// controls (zoom/follow/pan) are mutated by the dispatch goroutine and read as a
// snapshot each tick under mu.
type tvSession struct {
	cs   *connState
	w, h int
	stop chan struct{}

	mu     sync.Mutex
	zoom   float64
	follow string
	manual bool    // a tv.pan happened → freeze the lens on panX/panY
	panX   float64 // manual lens centre, display fraction 0..1
	panY   float64

	// The lens as actually captured, for tv.point and tv.state. A finger touches
	// the frame it can SEE, which the host may already have moved on from, so the
	// ring keeps the last 8 rects and tv.point echoes the sequence it was touching.
	lens     tvLens
	lensRing []tvLens
	lensSeq  int
	lensOK   bool
	// tv.state throttle state — change-driven, cursor capped, 1 s heartbeat.
	lastStateSeq    int
	lastStateFollow string
	lastStateManual bool
	lastCurX        int
	lastCurY        int
	lastStateAt     time.Time
	curX     int // cursor in physical pixels, sampled with the grab
	curY     int
}

var (
	tvMu       sync.Mutex
	tvSessions = map[*connState]*tvSession{}
)

// tvStart (re)starts the screen-mirror stream for a connection.
func tvStart(cs *connState, w, h int, zoom float64, follow string) {
	tvStop(cs)
	w = clampI(w, tvMinDim, tvMaxDim)
	h = clampI(h, tvMinDim, tvMaxDim)
	zoom = resolveTVZoom(zoom, w)
	if follow == "" {
		follow = "auto"
	}
	s := &tvSession{cs: cs, w: w, h: h, stop: make(chan struct{}), zoom: zoom, follow: follow}
	tvMu.Lock()
	tvSessions[cs] = s
	tvMu.Unlock()
	go s.loop()
	logf("tv on: %dx%d zoom %.1f follow %s", w, h, zoom, follow)
}

// tvStop ends the stream (idempotent — safe to call on a connection with none).
func tvStop(cs *connState) {
	tvMu.Lock()
	s := tvSessions[cs]
	delete(tvSessions, cs)
	tvMu.Unlock()
	if s != nil {
		close(s.stop)
	}
}

func tvWith(cs *connState, fn func(*tvSession)) {
	tvMu.Lock()
	s := tvSessions[cs]
	tvMu.Unlock()
	if s != nil {
		fn(s)
	}
}

func tvSetFollow(cs *connState, mode string) {
	if mode == "" {
		mode = "auto"
	}
	tvWith(cs, func(s *tvSession) {
		s.mu.Lock()
		s.follow = mode
		if mode == "off" {
			// "Stop following anything": freeze the lens where it is. Seeded from
			// the rect on screen (or the cursor before there is one), and it stays
			// frozen through pointer moves and typing until a follow is picked —
			// unlike a manual pan on macOS, which the next trackpad move exits.
			if !s.manual {
				if sw, sh := primaryScreenSize(); s.lensOK && sw > 0 && sh > 0 {
					s.panX = float64(s.lens.x+s.lens.w/2) / float64(sw)
					s.panY = float64(s.lens.y+s.lens.h/2) / float64(sh)
				} else {
					s.panX, s.panY = cursorFraction()
				}
				s.manual = true
			}
		} else {
			s.manual = false // an explicit follow choice cancels a manual pan
		}
		s.mu.Unlock()
	})
}

// resolveTVZoom turns a wire zoom into a real magnification.
//
// z <= 0 is the 1:1 pixel-perfect detent sentinel (mirroring macOS's
// Capture.setZoom / resolveNativeZoomLocked): the phone is not asking for "no
// zoom", it is asking for the magnification at which one captured pixel equals
// one streamed pixel — i.e. the captured region is exactly the stream width, so
// zoom = fovPx() / w.
//
// The old `if z < 1 { z = 1 }` did two bad things: it swallowed the sentinel, so
// the 1:1 pill did nothing on Windows, and it floored the whole 0.2–1.0 band, so
// zooming OUT past the base field of view was impossible here while macOS allowed
// it. The floor is 0.2 rather than macOS's 0.4-for-explicit-values because that is
// the band both sliders and the pinch path on the phone now span.
func resolveTVZoom(z float64, w int) float64 {
	if z <= 0 && w > 0 {
		z = fovPx() / float64(w)
	}
	return clampF(z, 0.2, 8)
}

func tvSetZoom(cs *connState, z float64) {
	tvWith(cs, func(s *tvSession) {
		s.mu.Lock()
		s.zoom = resolveTVZoom(z, s.w)
		s.mu.Unlock()
	})
}

// sendState pushes the lens's own truth. Change-driven with a 1 s heartbeat and a
// cursor cap, so it never rides at frame rate. Deliberately on the ordinary
// control send: the frame path is newest-wins one-in-flight, and a state push
// there would evict a pending frame.
func (s *tvSession) sendState(l tvLens) {
	if !l.ok {
		return
	}
	s.mu.Lock()
	changed := l.seq != s.lastStateSeq || l.follow != s.lastStateFollow || l.manual != s.lastStateManual
	cx, cy := s.curX, s.curY
	moved := absI(cx-s.lastCurX) > 1 || absI(cy-s.lastCurY) > 1
	now := time.Now()
	beat := now.Sub(s.lastStateAt) > time.Second
	rate := now.Sub(s.lastStateAt) > 100*time.Millisecond // cursor capped at ~10 Hz
	if !changed && !beat && !(moved && rate) {
		s.mu.Unlock()
		return
	}
	s.lastStateSeq, s.lastStateFollow, s.lastStateManual = l.seq, l.follow, l.manual
	s.lastCurX, s.lastCurY, s.lastStateAt = cx, cy, now
	s.mu.Unlock()

	msg := map[string]any{
		"t": "tv.state", "f": l.follow, "fr": l.resolved,
		"z": l.zoom, "nat": false, "m": l.mag, "sq": l.seq,
	}
	// Absence, not a lie: omitted when the cursor is outside the lens, so the phone
	// hides its puck rather than parking it in a corner.
	if l.w > 0 && l.h > 0 {
		u := float64(cx-l.x) / float64(l.w)
		v := float64(cy-l.y) / float64(l.h)
		if u >= 0 && u <= 1 && v >= 0 && v <= 1 {
			msg["cx"], msg["cy"] = u, v
		}
	}
	s.cs.send(msg)
}

func absI(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// tvPoint warps the real cursor to a point inside the lens the phone was looking
// at. The `seq` echo is what makes this correct while the lens is moving: in
// cursor-follow the rect re-centres on the cursor every tick, so mapping against
// the CURRENT rect would be wrong by one lens hop for a pointer in motion.
func tvPoint(cs *connState, u, v float64, seq int) {
	tvWith(cs, func(s *tvSession) {
		l := s.lensFor(seq)
		if !l.ok || l.w <= 0 || l.h <= 0 {
			return // no lens yet: DROP. Warping to the origin is worse than nothing.
		}
		x := int32(float64(l.x) + clampF(u, 0, 1)*float64(l.w))
		y := int32(float64(l.y) + clampF(v, 0, 1)*float64(l.h))
		warpCursorAbs(x, y)
		// Pin the lens, exactly as macOS does: otherwise the follow re-centres on the
		// cursor we just moved and drags the rect out from under the finger.
		s.mu.Lock()
		if !s.manual {
			sw, sh := primaryScreenSize()
			if sw > 0 && sh > 0 {
				s.panX = float64(l.x+l.w/2) / float64(sw)
				s.panY = float64(l.y+l.h/2) / float64(sh)
			}
			s.manual = true
		}
		s.mu.Unlock()
	})
}

func tvPan(cs *connState, dx, dy float64) {
	tvWith(cs, func(s *tvSession) {
		s.mu.Lock()
		if !s.manual {
			// Entering manual: seed the lens centre at the current cursor so the
			// first drag continues from where you were looking.
			s.panX, s.panY = cursorFraction()
			s.manual = true
		}
		s.panX = clampF(s.panX+dx, 0, 1)
		s.panY = clampF(s.panY+dy, 0, 1)
		s.mu.Unlock()
	})
}

func (s *tvSession) snapshot() (zoom float64, follow string, manual bool, panX, panY float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.zoom, s.follow, s.manual, s.panX, s.panY
}

// tvLens is one instant of the lens's truth, latched after a successful grab and
// handed to tv.point and tv.state. Mirrors macOS's TVLens.
type tvLens struct {
	x, y, w, h int // the region actually captured, PHYSICAL pixels
	seq        int // bumped ONLY when the rect changes, so `s` is a rect identity
	zoom       float64
	follow     string
	resolved   string
	manual     bool
	mag        float64 // stream px per captured px; the phone samples nearest-neighbour from 2
	ok         bool
}

// latchLens records the rect a frame was actually grabbed with, plus the cursor
// sampled in the same breath. Called from the capture goroutine right after a
// good grab, so the ring holds exactly the rects the phone could SEE.
func (s *tvSession) latchLens(x, y, w, h int, curX, curY int) tvLens {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.lensOK || s.lens.x != x || s.lens.y != y || s.lens.w != w || s.lens.h != h {
		s.lensSeq++
	}
	// Report "manual" as the MODE, not merely as the resolution. macOS's setPan
	// assigns follow = .manual outright, so reporting f:"cursor" here would light a
	// different pill on the phone depending on which host it is driving — exactly
	// the guessing tv.state exists to end.
	reported := s.follow
	if s.manual && s.follow != "off" {
		reported = "manual"
	}
	resolved := reported
	if s.manual && s.follow != "off" {
		resolved = "manual"
	} else if resolved == "auto" || resolved == "caret" {
		// No caret support on Windows — auto and caret both follow the pointer, and
		// saying so is better than reporting a mode the host is not in.
		resolved = "cursor"
	}
	l := tvLens{x: x, y: y, w: w, h: h, seq: s.lensSeq, follow: reported,
		resolved: resolved, manual: s.manual, ok: true}
	// The honest magnification of the pixels on screen, derived from the rect that
	// was cropped — never the stored request, which `full`, the region clamp and the
	// 1:1 detent all make into a lie.
	if w > 0 {
		l.zoom = fovPx() / float64(w)
		l.mag = float64(s.w) / float64(w)
	}
	s.lens = l
	s.lensOK = true
	s.curX, s.curY = curX, curY
	s.lensRing = append(s.lensRing, l)
	if len(s.lensRing) > 8 {
		s.lensRing = s.lensRing[len(s.lensRing)-8:]
	}
	return l
}

// lensFor returns the rect for a sequence, or the current one when seq is 0 (the
// phone has not rendered a frame yet) or too old to still be held.
func (s *tvSession) lensFor(seq int) tvLens {
	s.mu.Lock()
	defer s.mu.Unlock()
	if seq > 0 {
		for i := len(s.lensRing) - 1; i >= 0; i-- {
			if s.lensRing[i].seq == seq {
				return s.lensRing[i]
			}
		}
	}
	return s.lens
}

func (s *tvSession) loop() {
	// GDI DC/DIB handles are happiest pinned to one OS thread.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// Capturer creation can fail transiently (locked desktop, display off, RDP
	// session detach). Tell the phone once, then keep retrying while subscribed —
	// when the desktop comes back, frames resume and the first frame clears the
	// client-side error state.
	cap := newTVCapturer(s.w, s.h)
	for cap == nil {
		s.cs.send(map[string]any{"t": "tv.err", "err": "capture"})
		select {
		case <-s.stop:
			return
		case <-time.After(2500 * time.Millisecond):
		}
		cap = newTVCapturer(s.w, s.h)
	}
	defer cap.free()

	// A time.Ticker gives natural newest-wins backpressure: if a frame's
	// capture+encode+send runs long (slow link / busy CPU), intervening ticks are
	// dropped rather than queued, so we never backlog stale frames.
	ticker := time.NewTicker(time.Second / tvFPS)
	defer ticker.Stop()
	failStreak := 0

	// Encode + base64 is the expensive half of a frame (a pure-Go JPEG pass over
	// ~900k pixels) and it needs nothing from GDI, so it runs on its own
	// goroutine: frame N encodes while frame N+1 is being blitted. The channel
	// is depth-1 and the send is non-blocking, so a slow encoder DROPS the new
	// frame instead of backlogging stale ones — same newest-wins contract the
	// ticker already gives us.
	type pending struct {
		pix    []byte
		native bool
		mag    float64 // stream px per captured px — drives JPEG quality
	}
	// Two buffers cycle between the two goroutines: the capture side only ever
	// writes into a buffer it took off `free`, and the encoder returns it there
	// when it is done. Handing the encoder cap.rgba.Pix directly would have let
	// the next blit overwrite pixels mid-encode — torn frames, intermittently.
	frameBytes := len(cap.rgba.Pix)
	free := make(chan []byte, 2)
	free <- make([]byte, frameBytes)
	free <- make([]byte, frameBytes)
	work := make(chan pending, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		enc := &tvCapturer{}
		for p := range work {
			img := &image.RGBA{Pix: p.pix, Stride: cap.w * 4, Rect: image.Rect(0, 0, cap.w, cap.h)}
			b64, ok := enc.encodeB64(img, p.native, p.mag)
			free <- p.pix
			if !ok {
				continue
			}
			s.cs.send(map[string]any{"t": "tv.frame", "w": s.w, "h": s.h, "sq": s.lensFor(0).seq, "d": b64})
		}
	}()
	defer func() {
		close(work)
		<-done
	}()

	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
			sx, sy, sw, sh := s.region()
			if !cap.grab(sx, sy, sw, sh) {
				// A run of failed grabs = the desktop went away (lock screen,
				// display off). Tell the phone once per outage; the next good
				// frame clears the error client-side.
				failStreak++
				if failStreak == int(tvFPS) { // ~1s of nothing
					s.cs.send(map[string]any{"t": "tv.err", "err": "capture"})
				}
				continue
			}
			failStreak = 0
			// Latch the rect this frame was really grabbed with, and the cursor in
			// the same breath, BEFORE the encode — that pairing is what lets a later
			// tv.point map against the rect the finger could see.
			cpx, cpy := cursorPixels()
			lens := s.latchLens(sx, sy, sw, sh, cpx, cpy)
			s.sendState(lens)
			// ~1:1 or magnified: the phone paints at least one output pixel per
			// captured pixel, so quantisation is the visible ceiling, not scale.
			native := cap.w >= sw
			mag := 1.0
			if sw > 0 {
				mag = float64(cap.w) / float64(sw)
			}
			select {
			case buf := <-free:
				copy(buf, cap.rgba.Pix)
				select {
				case work <- pending{pix: buf, native: native, mag: mag}:
				default:
					free <- buf
				}
			default: // encoder is behind — drop this frame, newest-wins
			}
		}
	}
}

// fovPx converts the point-denominated base field of view into physical pixels
// for this display, so a given zoom shows the same physical area of screen as it
// does on macOS whatever scaling factor the user has set.
func fovPx() float64 {
	dc, _, _ := procGetDC.Call(0)
	if dc == 0 {
		return tvBaseFOV
	}
	dpi, _, _ := procGetDeviceCaps.Call(dc, uintptr(logPixelsX))
	procReleaseDC.Call(0, dc)
	if dpi == 0 {
		return tvBaseFOV
	}
	return tvBaseFOV * float64(dpi) / 96.0
}

// region computes the source rectangle (primary-screen px) for the current lens,
// mirroring Capture.swift's focusRegion/regionAround.
func (s *tvSession) region() (x, y, w, h int) {
	sw, sh := primaryScreenSize()
	zoom, follow, manual, panX, panY := s.snapshot()
	if follow == "full" {
		return 0, 0, sw, sh // whole display, scaled to the output — no magnification
	}
	regionW := fovPx() / zoom
	if regionW > float64(sw) {
		regionW = float64(sw)
	}
	regionH := regionW * float64(s.h) / float64(s.w)
	if regionH > float64(sh) {
		regionH = float64(sh)
		regionW = regionH * float64(s.w) / float64(s.h)
	}
	var cx, cy float64
	if manual {
		cx, cy = panX*float64(sw), panY*float64(sh)
	} else {
		// caret-follow isn't available on Windows yet → cursor for every
		// non-full mode (auto/cursor/caret all follow the pointer).
		px, py := cursorPixels()
		cx, cy = float64(px), float64(py)
	}
	ox := clampF(cx-regionW/2, 0, math.Max(0, float64(sw)-regionW))
	oy := clampF(cy-regionH/2, 0, math.Max(0, float64(sh)-regionH))
	return int(ox), int(oy), int(regionW + 0.5), int(regionH + 0.5)
}

// ---- GDI screen grab ----

type tvCapturer struct {
	memDC  uintptr
	bmp    uintptr
	oldBmp uintptr
	bits   []byte // DIB pixel memory, BGRA, top-down, w*h*4
	w, h   int
	rgba   *image.RGBA
	buf    bytes.Buffer
	// Screen DC is cached for the life of the stream: re-acquiring it every
	// frame is a needless round trip through the window manager 30x/s.
	screenDC uintptr
	// Last StretchBlt mode actually set, so we only pay for the state change
	// when the lens scale crosses the halftone threshold.
	blitMode uintptr
}

func newTVCapturer(w, h int) *tvCapturer {
	screenDC, _, _ := procGetDC.Call(0)
	if screenDC == 0 {
		return nil
	}
	memDC, _, _ := procCreateCompatibleDC.Call(screenDC)
	procReleaseDC.Call(0, screenDC)
	if memDC == 0 {
		return nil
	}
	// Negative height ⇒ top-down DIB (row 0 = top of screen), 32bpp BGRA.
	bi := bitmapInfoHeader{
		Size:        uint32(unsafe.Sizeof(bitmapInfoHeader{})),
		Width:       int32(w),
		Height:      -int32(h),
		Planes:      1,
		BitCount:    32,
		Compression: biRGB,
	}
	var bitsPtr unsafe.Pointer
	bmp, _, _ := procCreateDIBSection.Call(memDC, uintptr(unsafe.Pointer(&bi)), dibRGBColors, uintptr(unsafe.Pointer(&bitsPtr)), 0, 0)
	if bmp == 0 || bitsPtr == nil {
		procDeleteDC.Call(memDC)
		return nil
	}
	old, _, _ := procSelectObject.Call(memDC, bmp)
	procSetStretchBltMode.Call(memDC, colorOnColor)
	keptDC, _, _ := procGetDC.Call(0)
	return &tvCapturer{
		memDC:    memDC,
		bmp:      bmp,
		oldBmp:   old,
		bits:     unsafe.Slice((*byte)(bitsPtr), w*h*4),
		w:        w,
		h:        h,
		rgba:     image.NewRGBA(image.Rect(0, 0, w, h)),
		screenDC: keptDC,
		blitMode: colorOnColor,
	}
}

func (c *tvCapturer) free() {
	if c.screenDC != 0 {
		procReleaseDC.Call(0, c.screenDC)
		c.screenDC = 0
	}
	if c.memDC != 0 {
		procSelectObject.Call(c.memDC, c.oldBmp)
		procDeleteObject.Call(c.bmp)
		procDeleteDC.Call(c.memDC)
		c.memDC = 0
	}
}

// grabB64 StretchBlts the source rect from the live screen into the WxH DIB,
// JPEG-encodes it, and returns base64. ok=false on any GDI/encode failure.
// grab copies the source rect into the DIB and converts it to RGBA. It does NOT
// encode — encoding is the expensive half and runs on its own goroutine so the
// next frame's blit overlaps it (see tvSession.run).
func (c *tvCapturer) grab(srcX, srcY, srcW, srcH int) bool {
	if srcW <= 0 || srcH <= 0 || c.screenDC == 0 {
		return false
	}
	// Nearest-neighbour is free and indistinguishable near 1:1, but it drops
	// whole rows/columns when downscaling hard — which is exactly where text
	// lives. Pay for area-averaging only once the scale gets there.
	want := uintptr(colorOnColor)
	if float64(c.w) < float64(srcW)*tvHalftoneBelowScale {
		want = uintptr(halftoneMode)
	}
	if want != c.blitMode {
		procSetStretchBltMode.Call(c.memDC, want)
		c.blitMode = want
	}
	ret, _, _ := procStretchBlt.Call(
		c.memDC, 0, 0, uintptr(c.w), uintptr(c.h),
		c.screenDC, uintptr(srcX), uintptr(srcY), uintptr(srcW), uintptr(srcH),
		srcCopy,
	)
	if ret == 0 {
		return false
	}
	// GDI screen-copy omits the hardware cursor — composite it in so TV mode (and
	// especially cursor-follow) shows the pointer, matching the macOS host.
	c.drawCursor(srcX, srcY, srcW, srcH)
	c.toRGBA()
	return true
}

// toRGBA swaps the DIB's BGRA into the encoder's RGBA buffer. It is a per-pixel
// pass over the whole frame (~900k pixels at a typical lens size) and is pure
// bookkeeping, so it is split across cores — on the 30 fps budget this pass was
// costing more than the blit it follows.
func (c *tvCapturer) toRGBA() {
	src, dst := c.bits, c.rgba.Pix
	n := len(src)
	if len(dst) < n {
		n = len(dst)
	}
	n -= n % 4
	workers := runtime.NumCPU()
	if workers > 8 {
		workers = 8
	}
	rowBytes := c.w * 4
	if workers < 2 || rowBytes <= 0 || n < rowBytes*8 {
		swapBGRA(src, dst, 0, n)
		return
	}
	// Split on row boundaries so no worker straddles a pixel.
	rows := n / rowBytes
	var wg sync.WaitGroup
	chunk := (rows + workers - 1) / workers
	for r := 0; r < rows; r += chunk {
		hi := r + chunk
		if hi > rows {
			hi = rows
		}
		wg.Add(1)
		go func(lo, hi int) {
			defer wg.Done()
			swapBGRA(src, dst, lo*rowBytes, hi*rowBytes)
		}(r, hi)
	}
	wg.Wait()
}

func swapBGRA(src, dst []byte, lo, hi int) {
	for i := lo; i+3 < hi; i += 4 {
		dst[i+0] = src[i+2]
		dst[i+1] = src[i+1]
		dst[i+2] = src[i+0]
		dst[i+3] = 255
	}
}

// encodeB64 JPEG-encodes whatever grab() last produced. `native` picks the
// high-quality rung used when the phone is painting ~1:1.
func (c *tvCapturer) encodeB64(img *image.RGBA, native bool, mag float64) (string, bool) {
	// Quality rises with magnification (macOS parity): the more each captured
	// pixel is stretched on the phone, the more a JPEG block shows, and the fewer
	// real pixels there are to send — the bytes are cheap exactly when they help.
	// 55 at 1:1 or below, 85 by 3x.
	q := tvJPEGQuality + int(30*(mag-1))
	if q < tvJPEGQuality {
		q = tvJPEGQuality
	}
	if q > tvJPEGQualityNative {
		q = tvJPEGQualityNative
	}
	if native {
		q = tvJPEGQualityNative
	}
	c.buf.Reset()
	if err := jpeg.Encode(&c.buf, img, &jpeg.Options{Quality: q}); err != nil {
		return "", false
	}
	return base64.StdEncoding.EncodeToString(c.buf.Bytes()), true
}

// drawCursor composites the current mouse cursor onto the memDC after the screen
// copy, mapping its screen position into the lens region and scaling it to the
// output. Best-effort: hidden cursor / failed query just skips it.
func (c *tvCapturer) drawCursor(srcX, srcY, srcW, srcH int) {
	if srcW <= 0 || srcH <= 0 {
		return
	}
	var ci cursorInfo
	ci.cbSize = uint32(unsafe.Sizeof(ci))
	if r, _, _ := procGetCursorInfo.Call(uintptr(unsafe.Pointer(&ci))); r == 0 {
		return
	}
	if ci.flags&cursorShowing == 0 || ci.hCursor == 0 {
		return
	}
	var hotX, hotY int
	var ii iconInfo
	if r, _, _ := procGetIconInfo.Call(ci.hCursor, uintptr(unsafe.Pointer(&ii))); r != 0 {
		hotX, hotY = int(ii.xHotspot), int(ii.yHotspot)
		if ii.hbmMask != 0 {
			procDeleteObject.Call(ii.hbmMask)
		}
		if ii.hbmColor != 0 {
			procDeleteObject.Call(ii.hbmColor)
		}
	}
	scaleX := float64(c.w) / float64(srcW)
	scaleY := float64(c.h) / float64(srcH)
	drawX := (float64(int(ci.ptScreenPos.X)-srcX) - float64(hotX)) * scaleX
	drawY := (float64(int(ci.ptScreenPos.Y)-srcY) - float64(hotY)) * scaleY
	cw := int(float64(cursorBaseSize) * scaleX)
	ch := int(float64(cursorBaseSize) * scaleY)
	if cw < 10 {
		cw = 10
	}
	if ch < 10 {
		ch = 10
	}
	procDrawIconEx.Call(c.memDC, uintptr(int32(drawX)), uintptr(int32(drawY)), ci.hCursor, uintptr(cw), uintptr(ch), 0, 0, diNormal)
}

// ---- screen / cursor helpers ----

func primaryScreenSize() (int, int) {
	cx, _, _ := procGetSystemMetricsO.Call(smCXScreenO)
	cy, _, _ := procGetSystemMetricsO.Call(smCYScreenO)
	if cx == 0 || cy == 0 {
		return 1920, 1080
	}
	return int(cx), int(cy)
}

func cursorPixels() (int, int) {
	var p pointL
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&p)))
	return int(p.X), int(p.Y)
}

func cursorFraction() (float64, float64) {
	px, py := cursorPixels()
	sw, sh := primaryScreenSize()
	if sw == 0 || sh == 0 {
		return 0.5, 0.5
	}
	return clampF(float64(px)/float64(sw), 0, 1), clampF(float64(py)/float64(sh), 0, 1)
}
