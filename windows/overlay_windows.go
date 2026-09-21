//go:build windows

// Spotlight overlay for the Windows host (PROTOCOL.md "Spotlight overlay (v2)").
//
// A click-through, transparent, always-on-top window that covers the PRIMARY
// monitor and renders the presenter's "digital laser". It is purely a window —
// it injects no input and captures no input (WS_EX_TRANSPARENT + WS_EX_NOACTIVATE
// + WS_EX_LAYERED) — so it needs no special permission and never eats a real
// click on the presentation underneath.
//
// Rendering: we own a 32-bit top-down DIB section (premultiplied ARGB) the same
// size as the monitor, software-rasterize the active sub-mode into it on the Go
// side, and present it with UpdateLayeredWindow + per-pixel-alpha BLENDFUNCTION.
// Per-pixel alpha is what makes the dim translucent and the cutout a true hole
// while the window stays click-through.
//
// Threading: a Win32 message loop must run on ONE OS thread, so the window lives
// on its own goroutine (runtime.LockOSThread). The controller's public methods
// (called from the connection goroutine in dispatch) just push commands onto a
// channel and PostMessage a wake-up; all GDI/window work happens on the window
// thread. Runtime correctness on real Windows is UNVERIFIED (built/cross-checked
// only; no Windows box available here).

package main

import (
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ---- Win32 bindings -------------------------------------------------------

var (
	gdi32   = windows.NewLazySystemDLL("gdi32.dll")
	kernel  = windows.NewLazySystemDLL("kernel32.dll")
	user32o = windows.NewLazySystemDLL("user32.dll")

	procRegisterClassExW    = user32o.NewProc("RegisterClassExW")
	procCreateWindowExW     = user32o.NewProc("CreateWindowExW")
	procDefWindowProcW      = user32o.NewProc("DefWindowProcW")
	procGetMessageW         = user32o.NewProc("GetMessageW")
	procTranslateMessage    = user32o.NewProc("TranslateMessage")
	procDispatchMessageW    = user32o.NewProc("DispatchMessageW")
	procPostMessageW        = user32o.NewProc("PostMessageW")
	procShowWindow          = user32o.NewProc("ShowWindow")
	procSetWindowPos        = user32o.NewProc("SetWindowPos")
	procUpdateLayeredWindow = user32o.NewProc("UpdateLayeredWindow")
	procGetDC               = user32o.NewProc("GetDC")
	procReleaseDC           = user32o.NewProc("ReleaseDC")
	procGetSystemMetricsO   = user32o.NewProc("GetSystemMetrics")
	procDestroyWindow       = user32o.NewProc("DestroyWindow")
	procLoadCursorW         = user32o.NewProc("LoadCursorW")

	procCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	procCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	procSelectObject       = gdi32.NewProc("SelectObject")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procDeleteDC           = gdi32.NewProc("DeleteDC")

	procGetModuleHandleW = kernel.NewProc("GetModuleHandleW")
)

const (
	wsExLayered     = 0x00080000
	wsExTransparent = 0x00000020
	wsExTopmost     = 0x00000008
	wsExToolWindow  = 0x00000080
	wsExNoActivate  = 0x08000000

	wsPopup = 0x80000000

	swHide           = 0
	swShowNoActivate = 4

	ulwAlpha   = 0x00000002
	acSrcOver  = 0x00
	acSrcAlpha = 0x01

	biRGB        = 0
	dibRGBColors = 0

	wmApp     = 0x8000 // WM_APP — our "drain the command channel" wake-up
	wmDestroy = 0x0002

	cwUseDefault = ^uint32(0x7fffffff) // 0x80000000 (CW_USEDEFAULT)

	idcArrow = 32512

	smCXScreenO = 0
	smCYScreenO = 1
	// Virtual desktop origin — negative when a display sits left of / above the
	// primary one, so the overlay must be pinned there, not at (0,0).
	smXVirtualScreenO = 76
	smYVirtualScreenO = 77
	swpNoZOrder       = 0x0004
	swpNoActivate     = 0x0010
)

// BLENDFUNCTION (4 bytes) packed for UpdateLayeredWindow's per-pixel alpha.
type blendFunction struct {
	BlendOp             byte
	BlendFlags          byte
	SourceConstantAlpha byte
	AlphaFormat         byte
}

type pointL struct{ X, Y int32 }
type sizeL struct{ Cx, Cy int32 }

// BITMAPINFOHEADER + we treat it as a BITMAPINFO with no palette (32bpp).
type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

type wndClassExW struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   windows.Handle
	Icon       windows.Handle
	Cursor     windows.Handle
	Background windows.Handle
	MenuName   *uint16
	ClassName  *uint16
	IconSm     windows.Handle
}

type winMsg struct {
	Hwnd    windows.Handle
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      pointL
}

// ---- Command plumbing -----------------------------------------------------

type ovlCmdKind int

const (
	cmdMode ovlCmdKind = iota
	cmdMove
	cmdInk
	cmdClear
	cmdHide
	cmdTimer
)

type ovlCmd struct {
	kind ovlCmdKind
	mode string
	rf   float64
	dim  int
	// Audience countdown (§Presenter). The PHONE owns the clock and pushes
	// remaining seconds; the host only renders, so pause/resume and drift live
	// in one place instead of two clocks trying to agree.
	timerOn   bool
	timerSecs int
	timerWarn bool
	col  string
	x, y float64
	ink  string // ink phase
}

// Overlay is the process-wide controller. Public methods are called from the
// connection goroutine; they enqueue a command and poke the window thread.
type Overlay struct {
	cmds chan ovlCmd
	once sync.Once
	hwnd windows.Handle
	mu   sync.Mutex
}

func newOverlay() *Overlay {
	o := &Overlay{cmds: make(chan ovlCmd, 256)}
	o.once.Do(func() { go o.run() })
	return o
}

// SetMode activates a sub-mode (spotlight|square|pointer|annotate) or "off".
func (o *Overlay) SetMode(m string, rf float64, dim int, col string) {
	if m == "off" {
		o.enqueue(ovlCmd{kind: cmdHide})
		return
	}
	o.enqueue(ovlCmd{kind: cmdMode, mode: m, rf: rf, dim: dim, col: col})
}

func (o *Overlay) Move(x, y float64) { o.enqueue(ovlCmd{kind: cmdMove, x: x, y: y}) }
func (o *Overlay) Ink(phase string, x, y float64) {
	o.enqueue(ovlCmd{kind: cmdInk, ink: phase, x: x, y: y})
}
func (o *Overlay) Clear() { o.enqueue(ovlCmd{kind: cmdClear}) }

// SetTimer shows/hides the audience countdown. The phone owns the clock and
// pushes remaining seconds; the host only renders.
func (o *Overlay) SetTimer(on bool, secs int, warn bool) {
	o.enqueue(ovlCmd{kind: cmdTimer, timerOn: on, timerSecs: secs, timerWarn: warn})
}

// Reset hides + wipes the overlay (client disconnect / ovl.mode off).
func (o *Overlay) Reset() { o.enqueue(ovlCmd{kind: cmdHide}) }

func (o *Overlay) enqueue(c ovlCmd) {
	select {
	case o.cmds <- c:
	default:
		// Channel full (a stalled window thread). Drop the frame rather than
		// block the connection goroutine — overlay frames are advisory.
		return
	}
	o.mu.Lock()
	h := o.hwnd
	o.mu.Unlock()
	if h != 0 {
		// Wake the message loop so it drains the channel on its own thread.
		procPostMessageW.Call(uintptr(h), wmApp, 0, 0)
	}
}

// ---- Window thread --------------------------------------------------------

// renderer holds the current overlay state + the DIB it draws into. All access
// is from the window thread only.
type renderer struct {
	width, height int32
	hdc           uintptr // memory DC holding the DIB
	bitmap        uintptr // the DIB section bitmap
	oldBitmap     uintptr
	bits          []byte // pixel buffer aliasing the DIB memory (BGRA, top-down)
	pixPtr        unsafe.Pointer

	mode    string
	rf        float64
	dim       int
	timerOn   bool
	timerSecs int
	timerWarn bool
	r, g, b byte    // pointer/ink colour
	px, py  float64 // last pointer position (normalized)

	strokes [][]fpoint // finished + in-progress ink strokes
	drawing bool
	visible bool
}

type fpoint struct{ x, y float64 }

func (o *Overlay) run() {
	// A Win32 message loop is thread-affine: keep this goroutine pinned.
	runtime.LockOSThread()

	hInst, _, _ := procGetModuleHandleW.Call(0)
	className := windows.StringToUTF16Ptr("RemotypeOverlayWnd")

	cursor, _, _ := procLoadCursorW.Call(0, uintptr(idcArrow))
	wc := wndClassExW{
		Style:     0,
		WndProc:   windows.NewCallback(wndProc),
		Instance:  windows.Handle(hInst),
		Cursor:    windows.Handle(cursor),
		ClassName: className,
	}
	wc.Size = uint32(unsafe.Sizeof(wc))
	procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	cx, _, _ := procGetSystemMetricsO.Call(smCXScreenO) // primary width
	cy, _, _ := procGetSystemMetricsO.Call(smCYScreenO) // primary height
	w, h := int32(cx), int32(cy)
	if w <= 0 || h <= 0 {
		w, h = 1920, 1080
	}

	// Layered + transparent (click-through) + topmost + tool/no-activate so the
	// window never appears in alt-tab, never steals focus, never eats clicks.
	exStyle := uintptr(wsExLayered | wsExTransparent | wsExTopmost | wsExToolWindow | wsExNoActivate)
	hwnd, _, _ := procCreateWindowExW.Call(
		exStyle,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("Remotype Overlay"))),
		uintptr(wsPopup),
		0, 0, uintptr(w), uintptr(h),
		0, 0, hInst, 0,
	)
	if hwnd == 0 {
		return
	}
	o.mu.Lock()
	o.hwnd = windows.Handle(hwnd)
	o.mu.Unlock()

	rd := &renderer{width: w, height: h, mode: "off", rf: 0.12, dim: 0, r: 0x3D, g: 0x5B, b: 0xFF}
	rd.initDIB()

	// Drain any commands queued before the window existed, then enter the loop.
	o.drain(rd)

	var msg winMsg
	for {
		ret, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(ret) <= 0 { // 0 = WM_QUIT, -1 = error
			break
		}
		if msg.Message == wmApp {
			o.drain(rd)
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}
	rd.free()
}

// drain applies every queued command, then presents one frame if visible.
func (o *Overlay) drain(rd *renderer) {
	dirty := false
	for {
		select {
		case c := <-o.cmds:
			rd.apply(c)
			dirty = true
		default:
			if dirty {
				rd.present(o.hwnd)
			}
			return
		}
	}
}

// wndProc is minimal: the overlay does no painting in WM_PAINT (we present via
// UpdateLayeredWindow), captures no input, and just defers everything.
func wndProc(hwnd windows.Handle, message uint32, wParam, lParam uintptr) uintptr {
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

// ---- Renderer -------------------------------------------------------------

func (rd *renderer) initDIB() {
	hdc, _, _ := procGetDC.Call(0)
	memDC, _, _ := procCreateCompatibleDC.Call(hdc)
	procReleaseDC.Call(0, hdc)

	// Negative height ⇒ top-down DIB so row 0 is the top of the screen (matches
	// the protocol's top-left origin), 32bpp BGRA, no compression.
	bi := bitmapInfoHeader{
		Size:        uint32(unsafe.Sizeof(bitmapInfoHeader{})),
		Width:       rd.width,
		Height:      -rd.height,
		Planes:      1,
		BitCount:    32,
		Compression: biRGB,
	}
	var bitsPtr unsafe.Pointer
	bmp, _, _ := procCreateDIBSection.Call(
		memDC,
		uintptr(unsafe.Pointer(&bi)),
		dibRGBColors,
		uintptr(unsafe.Pointer(&bitsPtr)),
		0, 0,
	)
	old, _, _ := procSelectObject.Call(memDC, bmp)

	rd.hdc = memDC
	rd.bitmap = bmp
	rd.oldBitmap = old
	rd.pixPtr = bitsPtr
	n := int(rd.width) * int(rd.height) * 4
	// Alias the DIB memory as a Go byte slice so we can rasterize directly.
	rd.bits = unsafe.Slice((*byte)(bitsPtr), n)
}

func (rd *renderer) free() {
	if rd.hdc != 0 {
		procSelectObject.Call(rd.hdc, rd.oldBitmap)
		procDeleteObject.Call(rd.bitmap)
		procDeleteDC.Call(rd.hdc)
	}
}

func (rd *renderer) apply(c ovlCmd) {
	switch c.kind {
	case cmdMode:
		rd.mode = c.mode
		rd.rf = clampF(c.rf, 0.02, 0.5)
		rd.dim = clampI(c.dim, 0, 100)
		if cr, cg, cb, ok := parseHexColor(c.col); ok {
			rd.r, rd.g, rd.b = cr, cg, cb
		}
		if c.mode == "annotate" {
			// keep existing strokes when (re)entering annotate
		} else if c.mode != "annotate" {
			rd.drawing = false
		}
		rd.visible = true
	case cmdMove:
		rd.px, rd.py = clampF(c.x, 0, 1), clampF(c.y, 0, 1)
	case cmdInk:
		rd.applyInk(c.ink, clampF(c.x, 0, 1), clampF(c.y, 0, 1))
	case cmdTimer:
		rd.timerOn = c.timerOn
		rd.timerSecs = c.timerSecs
		rd.timerWarn = c.timerWarn
		if c.timerOn {
			rd.visible = true
		}
	case cmdClear:
		rd.strokes = nil
		rd.drawing = false
	case cmdHide:
		rd.mode = "off"
		rd.strokes = nil
		rd.drawing = false
		rd.visible = false
	}
}

func (rd *renderer) applyInk(phase string, x, y float64) {
	rd.px, rd.py = x, y
	switch phase {
	case "down":
		rd.strokes = append(rd.strokes, []fpoint{{x, y}})
		rd.drawing = true
	case "move":
		if rd.drawing && len(rd.strokes) > 0 {
			i := len(rd.strokes) - 1
			rd.strokes[i] = append(rd.strokes[i], fpoint{x, y})
		}
	default: // up
		rd.drawing = false
	}
}

// present rasterizes the current state into the DIB and pushes it to the screen
// with per-pixel alpha. When hidden, the window is simply ordered out.
func (rd *renderer) present(hwnd windows.Handle) {
	// The audience countdown is a mode of its own: it must render with no
	// spotlight or blank active, so "off" alone is not enough to hide.
	if !rd.visible || (rd.mode == "off" && !rd.timerOn) {
		procShowWindow.Call(uintptr(hwnd), swHide)
		return
	}
	rd.rasterize()

	// Pin the window to the whole virtual desktop EVERY present, in the same
	// physical pixels the DIB is drawn in. Without this the window kept the
	// size it was created with, and any disagreement between that size and the
	// buffer silently offset everything we draw — the audience countdown landed
	// below the screen edge and the spotlight sat low and right of the cursor.
	vx, _, _ := procGetSystemMetricsO.Call(smXVirtualScreenO)
	vy, _, _ := procGetSystemMetricsO.Call(smYVirtualScreenO)
	procSetWindowPos.Call(uintptr(hwnd), 0,
		uintptr(int32(vx)), uintptr(int32(vy)),
		uintptr(rd.width), uintptr(rd.height),
		uintptr(swpNoActivate|swpNoZOrder))

	procShowWindow.Call(uintptr(hwnd), swShowNoActivate)

	srcDC := rd.hdc
	pos := pointL{0, 0}
	size := sizeL{rd.width, rd.height}
	srcPos := pointL{0, 0}
	blend := blendFunction{BlendOp: acSrcOver, SourceConstantAlpha: 255, AlphaFormat: acSrcAlpha}
	// UpdateLayeredWindow(hwnd, hdcDst=0, &dstPos, &size, hdcSrc, &srcPos, 0,
	//                     &blend, ULW_ALPHA) — present the premultiplied BGRA DIB
	// with per-pixel alpha so the dim is translucent and the window click-through.
	procUpdateLayeredWindow.Call(
		uintptr(hwnd),
		0,
		uintptr(unsafe.Pointer(&pos)),
		uintptr(unsafe.Pointer(&size)),
		srcDC,
		uintptr(unsafe.Pointer(&srcPos)),
		0,
		uintptr(unsafe.Pointer(&blend)),
		ulwAlpha,
	)
}

// ---- Software rasterizer (writes premultiplied BGRA into rd.bits) ----------

func (rd *renderer) clearBits() {
	for i := range rd.bits {
		rd.bits[i] = 0
	}
}

// setPX writes a premultiplied BGRA pixel with src-over blending onto whatever
// is already in the buffer.
func (rd *renderer) blendPX(x, y int, r, g, b, a byte) {
	if x < 0 || y < 0 || x >= int(rd.width) || y >= int(rd.height) || a == 0 {
		return
	}
	i := (y*int(rd.width) + x) * 4
	// premultiply source
	sr := uint32(r) * uint32(a) / 255
	sg := uint32(g) * uint32(a) / 255
	sb := uint32(b) * uint32(a) / 255
	ia := 255 - uint32(a)
	// dst is already premultiplied
	db := uint32(rd.bits[i+0])
	dg := uint32(rd.bits[i+1])
	dr := uint32(rd.bits[i+2])
	da := uint32(rd.bits[i+3])
	rd.bits[i+0] = byte(sb + db*ia/255)
	rd.bits[i+1] = byte(sg + dg*ia/255)
	rd.bits[i+2] = byte(sr + dr*ia/255)
	rd.bits[i+3] = byte(uint32(a) + da*ia/255)
}

func (rd *renderer) rasterize() {
	switch rd.mode {
	case "spotlight":
		rd.rasterDim(true) // fills the whole buffer itself — no clear needed
	case "square":
		rd.rasterDim(false)
	case "pointer":
		rd.clearBits()
		rd.rasterPointer()
	case "annotate":
		rd.clearBits()
		rd.rasterInk()
	case "black":
		rd.fillOpaque(0, 0, 0)
		rd.rasterWatermark(false)
	case "white":
		rd.fillOpaque(255, 255, 255)
		rd.rasterWatermark(true)
	default:
		rd.clearBits()
	}

	// Drawn last so it stays legible over a blanked screen or a dimmed one.
	if rd.timerOn {
		rd.rasterTimer()
	}
}

// fillOpaque paints the entire buffer a solid colour — presentation blanking.
// Premultiplied, so an opaque fill is just the colour with alpha 255.
func (rd *renderer) fillOpaque(r, g, b byte) {
	bts := rd.bits
	if len(bts) < 4 {
		return
	}
	bts[0], bts[1], bts[2], bts[3] = b, g, r, 255
	for i := 4; i < len(bts); i *= 2 {
		copy(bts[i:], bts[:i])
	}
}

// fillDim paints the entire buffer with the flat backdrop colour (premultiplied
// black at alpha a) using a doubling copy, which the runtime turns into a few
// large memmoves instead of millions of per-pixel writes.
func (rd *renderer) fillDim(a byte) {
	b := rd.bits
	if len(b) < 4 {
		return
	}
	b[0], b[1], b[2], b[3] = 0, 0, 0, a
	for i := 4; i < len(b); i *= 2 {
		copy(b[i:], b[:i])
	}
}

// rasterDim fills the screen with a translucent black backdrop, punching a
// soft-edged hole (circle or rectangle) around the pointer.
func (rd *renderer) rasterDim(circle bool) {
	w, h := int(rd.width), int(rd.height)
	short := w
	if h < w {
		short = h
	}
	radius := rd.rf * float64(short)
	cx := rd.px * float64(w)
	cy := rd.py * float64(h)
	dimA := byte(rd.dim * 255 / 100)
	// Just enough to antialias the cutout, not a gradient. This was radius*0.18
	// (~50px at a normal size), which turned macOS's crisp edge into a haze.
	feather := radius * 0.035
	if feather < 2 {
		feather = 2
	}

	// rectangle half-extents (square sub-mode reads ~16:10)
	rxHalf := radius * 1.6
	ryHalf := radius * 0.99

	// A colored ring on the cutout edge. macOS strokes a CRISP line and adds a
	// separate glow; this used to be one broad linear falloff over
	// max(feather*2.2, 7) px, which read as a fuzzy halo with no defined edge —
	// visibly different from the Mac. Now: a narrow solid core with a soft halo
	// outside it, which is what the Mac's stroke+shadow actually looks like.
	ringCore := maxF(radius*0.012, 2)        // the crisp line itself
	ringGlow := maxF(radius*0.045, 10)       // short halo, matching the Mac's shadow
	ringWidth := ringCore + ringGlow

	// Everything further out than the ring+feather is a flat dim, and everything
	// well inside the cutout is a flat hole — only the band between them needs
	// the per-pixel distance math. Paint the flat majority in a few memmoves and
	// confine the float work to the band's bounding box: at a native-DPI
	// 2736x1824 that is ~375k pixels a frame instead of 5M.
	rd.fillDim(dimA)
	margin := maxF(feather, ringWidth) + 2
	bx0, bx1 := cx-rxHalf-margin, cx+rxHalf+margin
	by0, by1 := cy-ryHalf-margin, cy+ryHalf+margin
	if circle {
		bx0, bx1 = cx-radius-margin, cx+radius+margin
		by0, by1 = cy-radius-margin, cy+radius+margin
	}
	x0, y0 := clampI(int(bx0), 0, w), clampI(int(by0), 0, h)
	x1, y1 := clampI(int(bx1)+1, 0, w), clampI(int(by1)+1, 0, h)

	for y := y0; y < y1; y++ {
		fy := float64(y)
		row := y * w * 4
		for x := x0; x < x1; x++ {
			fx := float64(x)
			// Recomputing from scratch, so drop the flat dim this pixel got
			// from fillDim before blending the real value onto it.
			i := row + x*4
			rd.bits[i+0], rd.bits[i+1], rd.bits[i+2], rd.bits[i+3] = 0, 0, 0, 0
			var dimFrac float64 // 0 INSIDE cutout (clear, real screen shows through), 1 OUTSIDE (full dim)
			var sd float64      // SIGNED distance to the cutout edge: <0 inside, 0 on edge, >0 outside
			if circle {
				d := dist(fx, fy, cx, cy)
				dimFrac = smoothEdge(d, radius, feather)
				sd = d - radius
			} else {
				// distance outside the rect on each axis
				dx := absF(fx-cx) - rxHalf
				dy := absF(fy-cy) - ryHalf
				od := maxF(maxF(dx, dy), 0)
				dimFrac = smoothEdge(od, 0, feather)
				// signed box distance: euclidean outside + (negative) inside
				inside := maxF(dx, dy)
				if inside > 0 {
					inside = 0
				}
				sd = dist(maxF(dx, 0), maxF(dy, 0), 0, 0) + inside
			}
			a := byte(float64(dimA) * dimFrac)
			if a > 0 {
				rd.blendPX(x, y, 0, 0, 0, a)
			}
			// Colored ring on top (over the dim outside, over the clear screen inside).
			if ringDist := absF(sd); ringDist < ringWidth {
				var ringA float64
				if ringDist <= ringCore {
					ringA = 0.95 // solid core — this is the edge the eye locks onto
				} else {
					g := (ringDist - ringCore) / ringGlow
					ringA = (1 - g) * (1 - g) * 0.55 // quadratic halo, falls off fast
				}
				if ringA > 0 {
					rd.blendPX(x, y, rd.r, rd.g, rd.b, byte(ringA*255))
				}
			}
		}
	}
}

// rasterPointer draws a small laser dot: a soft coloured glow, a coloured core,
// and a white-hot centre on top — NOT a big blob (matches the Mac reference).
func (rd *renderer) rasterPointer() {
	w, h := int(rd.width), int(rd.height)
	short := w
	if h < w {
		short = h
	}
	radius := rd.rf * float64(short)
	core := maxF(7, radius*0.16) // small coloured core
	glow := core * 2.0           // tight halo — 3x read as a diffuse blob
	centre := maxF(3, core*0.42) // white-hot centre
	cx := rd.px * float64(w)
	cy := rd.py * float64(h)

	x0, y0 := int(cx-glow)-1, int(cy-glow)-1
	x1, y1 := int(cx+glow)+1, int(cy+glow)+1
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			d := dist(float64(x), float64(y), cx, cy)
			// glow falloff
			if d <= glow {
				// Quadratic, not linear: falls away fast so the dot keeps a
				// defined edge instead of bleeding into a haze.
				f := 1 - d/glow
				ga := 0.62 * f * f
				rd.blendPX(x, y, rd.r, rd.g, rd.b, byte(ga*255))
			}
			// solid coloured core (feathered)
			if d <= core+1 {
				ca := smoothEdge(d, core, 1.2)
				rd.blendPX(x, y, rd.r, rd.g, rd.b, byte((1-ca)*255))
			}
			// white centre
			if d <= centre+1 {
				wa := smoothEdge(d, centre, 1.0)
				rd.blendPX(x, y, 255, 255, 255, byte((1-wa)*255))
			}
		}
	}
}

// rasterInk strokes every freehand path with a round-capped coloured line.
func (rd *renderer) rasterInk() {
	w, h := float64(rd.width), float64(rd.height)
	const lineHalf = 2.5 // 5px stroke
	for _, s := range rd.strokes {
		if len(s) == 1 {
			// lone dot
			rd.disc(s[0].x*w, s[0].y*h, lineHalf)
			continue
		}
		for i := 1; i < len(s); i++ {
			rd.segment(s[i-1].x*w, s[i-1].y*h, s[i].x*w, s[i].y*h, lineHalf)
		}
	}
}

// disc paints a filled, feathered circle of the ink colour.
func (rd *renderer) disc(cx, cy, r float64) {
	x0, y0 := int(cx-r)-1, int(cy-r)-1
	x1, y1 := int(cx+r)+1, int(cy+r)+1
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			d := dist(float64(x), float64(y), cx, cy)
			a := smoothEdge(d, r, 1.0)
			if a < 1 {
				rd.blendPX(x, y, rd.r, rd.g, rd.b, byte((1-a)*255))
			}
		}
	}
}

// segment paints a round-capped line by walking discs along it (simple but
// adequate for ~60Hz ink; the points are dense so caps overlap smoothly).
func (rd *renderer) segment(x0, y0, x1, y1, r float64) {
	dx, dy := x1-x0, y1-y0
	length := dist(x0, y0, x1, y1)
	if length < 0.5 {
		rd.disc(x0, y0, r)
		return
	}
	steps := int(length) + 1
	for i := 0; i <= steps; i++ {
		t := float64(i) / float64(steps)
		rd.disc(x0+dx*t, y0+dy*t, r)
	}
}

// ---- helpers --------------------------------------------------------------

func dist(ax, ay, bx, by float64) float64 {
	dx, dy := ax-bx, ay-by
	return sqrt(dx*dx + dy*dy)
}

// smoothEdge returns 0 inside `edge`, 1 beyond edge+feather, and a smooth ramp
// across the feather band — an anti-aliased boundary.
func smoothEdge(d, edge, feather float64) float64 {
	if d <= edge {
		return 0
	}
	if d >= edge+feather {
		return 1
	}
	return (d - edge) / feather
}

func absF(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}
func maxF(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
func clampF(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
func clampI(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// sqrt — small Newton iteration so the rasterizer needs no math import churn.
func sqrt(x float64) float64 {
	if x <= 0 {
		return 0
	}
	z := x
	for i := 0; i < 20; i++ {
		z = (z + x/z) / 2
	}
	return z
}

// parseHexColor parses "RRGGBB" → bytes. ok=false leaves the current colour.
func parseHexColor(s string) (r, g, b byte, ok bool) {
	if len(s) != 6 {
		return 0, 0, 0, false
	}
	v := 0
	for _, c := range s {
		var d int
		switch {
		case c >= '0' && c <= '9':
			d = int(c - '0')
		case c >= 'a' && c <= 'f':
			d = int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = int(c-'A') + 10
		default:
			return 0, 0, 0, false
		}
		v = v<<4 | d
	}
	return byte(v >> 16), byte(v >> 8), byte(v), true
}

// ---- audience countdown -----------------------------------------------------

// rasterTimer draws MM:SS large in the lower third of the display.
//
// GDI text and UpdateLayeredWindow disagree about alpha: DrawTextW writes RGB
// and leaves the alpha byte alone, which a per-pixel-alpha layered window then
// treats as fully transparent. So the digits are drawn WHITE ON BLACK into a
// scratch DIB and composited here using their own luminance as the alpha —
// which also gives free antialiasing on the glyph edges.
func (rd *renderer) rasterTimer() {
	secs := rd.timerSecs
	neg := secs < 0
	if neg {
		secs = -secs
	}
	label := fmt.Sprintf("%d:%02d", secs/60, secs%60)
	if neg {
		label = "-" + label
	}

	w, h := int(rd.width), int(rd.height)
	// Big enough to read from the back of a room, capped so it never dominates.
	fontH := h * 22 / 100
	if fontH > 320 {
		fontH = 320
	}
	if fontH < 64 {
		fontH = 64
	}
	boxH := fontH * 5 / 4
	boxY := h - h*12/100 - boxH
	if boxY < 0 {
		boxY = 0
	}

	dc, _, _ := procCreateCompatibleDC.Call(0)
	if dc == 0 {
		return
	}
	defer procDeleteDC.Call(dc)

	bi := bitmapInfoHeader{
		Size: 40, Width: int32(w), Height: -int32(boxH), // top-down
		Planes: 1, BitCount: 32, Compression: biRGB,
	}
	var bitsPtr unsafe.Pointer
	bmp, _, _ := procCreateDIBSection.Call(dc, uintptr(unsafe.Pointer(&bi)),
		dibRGBColors, uintptr(unsafe.Pointer(&bitsPtr)), 0, 0)
	if bmp == 0 || bitsPtr == nil {
		return
	}
	defer procDeleteObject.Call(bmp)
	old, _, _ := procSelectObject.Call(dc, bmp)
	defer procSelectObject.Call(dc, old)

	font, _, _ := procCreateFontW.Call(
		uintptr(int32(fontH)), 0, 0, 0, 700 /*FW_BOLD*/, 0, 0, 0,
		1 /*DEFAULT_CHARSET*/, 0, 0, 4 /*ANTIALIASED_QUALITY*/, 0,
		uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("Segoe UI"))),
	)
	if font != 0 {
		oldFont, _, _ := procSelectObject.Call(dc, font)
		defer func() { procSelectObject.Call(dc, oldFont); procDeleteObject.Call(font) }()
	}
	procSetBkMode.Call(dc, 1 /*TRANSPARENT*/)
	procSetTextColor.Call(dc, 0x00FFFFFF) // white; luminance becomes alpha

	rect := struct{ L, T, R, B int32 }{0, 0, int32(w), int32(boxH)}
	u16, _ := windows.UTF16FromString(label)
	procDrawTextW.Call(dc, uintptr(unsafe.Pointer(&u16[0])), uintptr(len(label)),
		uintptr(unsafe.Pointer(&rect)),
		uintptr(0x00000001|0x00000004|0x00000020)) // CENTER|VCENTER|SINGLELINE

	// On a WHITE blank the screen is white: white text is invisible, so the
	// countdown flips to ink (and to a darker red when it is alarming).
	onWhite := rd.mode == "white"
	var tr, tg, tb byte = 255, 255, 255
	if onWhite {
		tr, tg, tb = 0, 0, 0
	}
	if rd.timerWarn || neg {
		if onWhite {
			tr, tg, tb = 184, 0, 0
		} else {
			tr, tg, tb = 255, 105, 97
		}
	}
	src := unsafe.Slice((*byte)(bitsPtr), w*boxH*4)
	for y := 0; y < boxH; y++ {
		dy := boxY + y
		if dy < 0 || dy >= h {
			continue
		}
		for x := 0; x < w; x++ {
			i := (y*w + x) * 4
			// Grey text on black: any channel is the coverage value.
			a := src[i+2]
			if a == 0 {
				continue
			}
			rd.blendPX(x, dy, tr, tg, tb, a)
		}
	}
}

// rasterWatermark draws a quiet "R Remotype" mark in the bottom-left while the
// screen is blanked. A blank projector with nothing on it looks broken; a small
// mark says the blanking is deliberate. Faint on purpose — it must not compete
// with the presenter.
func (rd *renderer) rasterWatermark(onWhite bool) {
	h := int(rd.height)
	tile := h * 28 / 1000
	if tile < 22 {
		tile = 22
	}
	pad := tile * 14 / 10
	x0, y0 := pad, h-pad-tile

	// Accent tile with a white R — the same mark the phone and menu bar use.
	radius := tile / 4
	for y := y0; y < y0+tile; y++ {
		for x := x0; x < x0+tile; x++ {
			// rounded corners
			dx, dy := 0, 0
			if x < x0+radius {
				dx = x0 + radius - x
			} else if x >= x0+tile-radius {
				dx = x - (x0 + tile - radius - 1)
			}
			if y < y0+radius {
				dy = y0 + radius - y
			} else if y >= y0+tile-radius {
				dy = y - (y0 + tile - radius - 1)
			}
			if dx > 0 && dy > 0 && dx*dx+dy*dy > radius*radius {
				continue
			}
			rd.blendPX(x, y, 0x3D, 0x5B, 0xFF, 100)
		}
	}
	drawWatermarkText(rd, "R", x0, y0, tile, tile, 255, 255, 255, 130, true)

	var tr, tg, tb byte = 255, 255, 255
	if onWhite {
		tr, tg, tb = 0, 0, 0
	}
	drawWatermarkText(rd, "Remotype", x0+tile+tile/3, y0, tile*6, tile, tr, tg, tb, 105, false)
}

// drawWatermarkText renders a short string with GDI and composites it using its
// own luminance as alpha (same trick as the countdown — DrawTextW leaves the
// alpha byte alone, which a per-pixel-alpha layered window reads as transparent).
func drawWatermarkText(rd *renderer, label string, x0, y0, boxW, boxH int,
	tr, tg, tb byte, alpha float64, center bool) {
	dc, _, _ := procCreateCompatibleDC.Call(0)
	if dc == 0 {
		return
	}
	defer procDeleteDC.Call(dc)
	bi := bitmapInfoHeader{Size: 40, Width: int32(boxW), Height: -int32(boxH),
		Planes: 1, BitCount: 32, Compression: biRGB}
	var bits unsafe.Pointer
	bmp, _, _ := procCreateDIBSection.Call(dc, uintptr(unsafe.Pointer(&bi)),
		dibRGBColors, uintptr(unsafe.Pointer(&bits)), 0, 0)
	if bmp == 0 || bits == nil {
		return
	}
	defer procDeleteObject.Call(bmp)
	old, _, _ := procSelectObject.Call(dc, bmp)
	defer procSelectObject.Call(dc, old)

	fh := boxH * 62 / 100
	font, _, _ := procCreateFontW.Call(uintptr(int32(fh)), 0, 0, 0, 600, 0, 0, 0,
		1, 0, 0, 4, 0, uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("Segoe UI"))))
	if font != 0 {
		of, _, _ := procSelectObject.Call(dc, font)
		defer func() { procSelectObject.Call(dc, of); procDeleteObject.Call(font) }()
	}
	procSetBkMode.Call(dc, 1)
	procSetTextColor.Call(dc, 0x00FFFFFF)
	rect := struct{ L, T, R, B int32 }{0, 0, int32(boxW), int32(boxH)}
	u16, _ := windows.UTF16FromString(label)
	flags := uintptr(0x00000004 | 0x00000020) // VCENTER|SINGLELINE
	if center {
		flags |= 0x00000001 // CENTER
	}
	procDrawTextW.Call(dc, uintptr(unsafe.Pointer(&u16[0])), uintptr(len(label)),
		uintptr(unsafe.Pointer(&rect)), flags)

	src := unsafe.Slice((*byte)(bits), boxW*boxH*4)
	for y := 0; y < boxH; y++ {
		for x := 0; x < boxW; x++ {
			cov := src[(y*boxW+x)*4+2]
			if cov == 0 {
				continue
			}
			rd.blendPX(x0+x, y0+y, tr, tg, tb, byte(float64(cov)*alpha/255))
		}
	}
}
