//go:build windows

// Shared drawing for the host's own windows — About, Pair a phone, Set up.
//
// It exists because of one line in dpi_windows.go: the process declares itself
// PER-MONITOR-AWARE-V2, which tells Windows "do not scale me, I know what I am
// doing". Every window here was then written in raw pixels, so on a 150 %
// display — which is most laptops — the text and buttons came out at two-thirds
// size: small type, buttons you could barely hit, content clipped off the
// bottom of a window that was itself too short. Declaring DPI awareness and then
// ignoring DPI is worse than never declaring it.
//
// So: every size in the windows above is a DESIGN pixel at 100 %, and goes
// through [uiCtx.px]. Nothing is a raw constant, fonts included.
package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	procGetDpiForWindow          = user32o.NewProc("GetDpiForWindow")
	procGetWindowRect = user32o.NewProc("GetWindowRect")
	procFlashWindowEx = user32o.NewProc("FlashWindowEx")
	procGetDpiForSystem          = user32o.NewProc("GetDpiForSystem")
	procAdjustWindowRectExForDpi = user32o.NewProc("AdjustWindowRectExForDpi")
	procGetWindowLongPtr         = user32o.NewProc("GetWindowLongPtrW")
	procAdjustWindowRect         = user32o.NewProc("AdjustWindowRect")
	procSystemParametersInfo     = user32o.NewProc("SystemParametersInfoW")

	procCreateCompatibleBitmap = gdi32.NewProc("CreateCompatibleBitmap")
	procBitBlt                 = gdi32.NewProc("BitBlt")
)

const (
	wmEraseBkgnd    = 0x0014
	wmSize          = 0x0005
	wmDpiChanged    = 0x02E0
	wmGetMinMaxInfo = 0x0024

	wsThickFrame  = 0x00040000
	wsMinimizeBox = 0x00020000

	gwlStyle = ^uintptr(15) // -16
)

// uiCtx carries the scale for one paint pass, and the fonts made for it.
//
// Fonts are created per paint and deleted at the end. That is a few GDI objects
// per repaint rather than a cache keyed by DPI — on windows that repaint at most
// once a second it is not worth the leak risk of getting the cache wrong.
type uiCtx struct {
	scale float64
	hdc   uintptr
	fonts []uintptr

	// Double buffering. These windows repaint their whole client area on a
	// timer — the pairing code counts down every second — and painting straight
	// onto the window DC meant every tick erased and redrew the background
	// under the text, which reads as a flicker. Everything is drawn into a
	// memory bitmap and blitted once.
	hwnd     windows.Handle
	winDC    uintptr
	memBmp   uintptr
	oldBmp   uintptr
	w, h     int32
	ps       paintStruct
	buffered bool
}

// beginPaint starts a buffered paint and returns the client rect. Pair it with
// a deferred `u.endPaint()`; do not call BeginPaint/EndPaint directly.
func beginPaint(hwnd windows.Handle) (*uiCtx, rect) {
	u := &uiCtx{hwnd: hwnd, scale: scaleForWindow(hwnd)}
	dc, _, _ := procBeginPaint.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&u.ps)))
	u.winDC = dc
	u.hdc = dc

	var rc rect
	procGetClientRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&rc)))
	u.w = rc.Right - rc.Left
	u.h = rc.Bottom - rc.Top

	if u.w > 0 && u.h > 0 {
		mem, _, _ := procCreateCompatibleDC.Call(dc)
		if mem != 0 {
			bmp, _, _ := procCreateCompatibleBitmap.Call(dc, uintptr(u.w), uintptr(u.h))
			if bmp != 0 {
				old, _, _ := procSelectObject.Call(mem, bmp)
				u.hdc = mem
				u.memBmp = bmp
				u.oldBmp = old
				u.buffered = true
			} else {
				procDeleteDC.Call(mem)
			}
		}
	}
	return u, rc
}

func (u *uiCtx) endPaint() {
	if u.buffered {
		procBitBlt.Call(u.winDC, 0, 0, uintptr(u.w), uintptr(u.h), u.hdc, 0, 0, srcCopy)
		procSelectObject.Call(u.hdc, u.oldBmp)
		procDeleteObject.Call(u.memBmp)
		procDeleteDC.Call(u.hdc)
	}
	u.release()
	procEndPaint.Call(uintptr(u.hwnd), uintptr(unsafe.Pointer(&u.ps)))
}

// px converts a design pixel (at 100 % scaling) to a device pixel.
func (u *uiCtx) px(v int) int32 {
	return int32(float64(v)*u.scale + 0.5)
}

// font makes a font whose height is a DESIGN size, scaled. Every font in these
// windows goes through here; a raw CreateFontW is a bug.
func (u *uiCtx) font(designPx int, weight int32) uintptr {
	f := newFont(int32(float64(designPx)*u.scale+0.5), weight)
	u.fonts = append(u.fonts, f)
	return f
}

func (u *uiCtx) release() {
	for _, f := range u.fonts {
		procDeleteObject.Call(f)
	}
	u.fonts = nil
}

func (u *uiCtx) fill(r rect, color uintptr) {
	brush, _, _ := procCreateSolidBrush.Call(color)
	rr := r
	procFillRect.Call(u.hdc, uintptr(unsafe.Pointer(&rr)), brush)
	procDeleteObject.Call(brush)
}

func (u *uiCtx) text(s string, font, color uintptr, r rect, flags uintptr) {
	procSelectObject.Call(u.hdc, font)
	procSetTextColor.Call(u.hdc, color)
	rr := r
	p := windows.StringToUTF16Ptr(s)
	procDrawTextW.Call(u.hdc, uintptr(unsafe.Pointer(p)), ^uintptr(0),
		uintptr(unsafe.Pointer(&rr)), flags|dtNoPrefix)
}

// textHeight measures how tall `s` will be when wrapped to `width`, so a block
// of prose can push what follows down instead of overlapping it. The fixed
// line-count guesses this code used before are exactly how text ended up
// underneath a button.
func (u *uiCtx) textHeight(s string, font uintptr, width int32) int32 {
	procSelectObject.Call(u.hdc, font)
	r := rect{Left: 0, Top: 0, Right: width, Bottom: 0}
	p := windows.StringToUTF16Ptr(s)
	const dtCalcRect = 0x00000400
	procDrawTextW.Call(u.hdc, uintptr(unsafe.Pointer(p)), ^uintptr(0),
		uintptr(unsafe.Pointer(&r)), uintptr(dtLeft|dtWordBreak|dtNoPrefix|dtCalcRect))
	return r.Bottom - r.Top
}

// scaleForWindow reports the monitor scale for a window (1.0 at 96 DPI).
func scaleForWindow(hwnd windows.Handle) float64 {
	if procGetDpiForWindow.Find() == nil {
		if dpi, _, _ := procGetDpiForWindow.Call(uintptr(hwnd)); dpi > 0 {
			return float64(dpi) / 96
		}
	}
	return systemScale()
}

func systemScale() float64 {
	if procGetDpiForSystem.Find() == nil {
		if dpi, _, _ := procGetDpiForSystem.Call(); dpi > 0 {
			return float64(dpi) / 96
		}
	}
	return 1
}

// sizeWindowForClient resizes `hwnd` so its CLIENT area is the given design size
// at the window's own DPI, and centres it.
//
// Getting this wrong is what clipped the setup wizard's buttons: CreateWindowEx
// takes the OUTER size, so a 600-tall window has roughly 560 of usable height on
// a 100 % display and less on a scaled one — and the buttons were drawn at 556.
func sizeWindowForClient(hwnd windows.Handle, designW, designH int) {
	scale := scaleForWindow(hwnd)
	w := int32(float64(designW)*scale + 0.5)
	h := int32(float64(designH)*scale + 0.5)

	style := uintptr(wsCaption | wsSysMenu | wsThickFrame | wsMinimizeBox)
	if procGetWindowLongPtr.Find() == nil {
		if s, _, _ := procGetWindowLongPtr.Call(uintptr(hwnd), gwlStyle); s != 0 {
			style = s
		}
	}

	r := rect{Left: 0, Top: 0, Right: w, Bottom: h}
	if procAdjustWindowRectExForDpi.Find() == nil {
		dpi := uintptr(scale*96 + 0.5)
		procAdjustWindowRectExForDpi.Call(uintptr(unsafe.Pointer(&r)), style, 0, 0, dpi)
	} else {
		procAdjustWindowRect.Call(uintptr(unsafe.Pointer(&r)), style, 0)
	}
	outW := r.Right - r.Left
	outH := r.Bottom - r.Top

	// Never larger than the desktop. A design size chosen on a big monitor
	// becomes an unusable window on a 1280x1024 screen at 150 % scaling —
	// bigger-than-the-screen is the same failure as too-small, from the other
	// direction, and the layout code already copes with being squeezed because
	// it measures rather than guesses.
	wa := workArea()
	if maxW := wa.Right - wa.Left - int32(float64(40)*scale); outW > maxW {
		outW = maxW
	}
	if maxH := wa.Bottom - wa.Top - int32(float64(40)*scale); outH > maxH {
		outH = maxH
	}

	x := wa.Left + (wa.Right-wa.Left-outW)/2
	y := wa.Top + (wa.Bottom-wa.Top-outH)/2
	if x < 0 {
		x = 0
	}
	if y < 0 {
		y = 0
	}
	procSetWindowPos.Call(uintptr(hwnd), 0, uintptr(x), uintptr(y),
		uintptr(outW), uintptr(outH), swpNoZOrder|swpNoActivate)
}

// uiButton draws a filled button and RETURNS its rect, so the click test can
// never disagree with what was drawn — the two used to be separate constants.
func (u *uiCtx) button(label string, font uintptr, r rect, fill, fg uintptr) rect {
	u.fill(r, fill)
	u.text(label, font, fg, r, dtCenter|dtVCenter|dtSingleLine)
	return r
}

// minMaxInfo is the MINMAXINFO Windows passes on WM_GETMINMAXINFO.
type minMaxInfo struct {
	Reserved     point
	MaxSize      point
	MaxPosition  point
	MinTrackSize point
	MaxTrackSize point
}

type point struct{ X, Y int32 }

// clampMinSize answers WM_GETMINMAXINFO with a floor, in design pixels.
//
// Making these windows resizable without one would trade a window that is too
// small by default for a window the user can drag until the text lands on the
// buttons — a worse bug, and one they would have caused themselves.
// fitIntoWorkArea moves — and if it must, shrinks — a top-level window so the
// whole of it is on the primary work area. Two things put a window off-screen
// here: CreateWindowEx's cascade position (CW_USEDEFAULT) combined with a size
// computed for a high-DPI display, and WM_DPICHANGED's suggested rect, which
// keeps the old top-left. Either way the user saw a "Pair a phone" window whose
// right edge (the title-bar close box) and bottom edge (the Close button) were
// past the screen — a window with no way to dismiss it.
func fitIntoWorkArea(hwnd windows.Handle) {
	var r rect
	if ok, _, _ := procGetWindowRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&r))); ok == 0 {
		return
	}
	wa := workArea()
	w, h := r.Right-r.Left, r.Bottom-r.Top
	logf("ui: fit window rect=(%d,%d %dx%d) workarea=(%d,%d,%d,%d) scale=%.2f", r.Left, r.Top, w, h, wa.Left, wa.Top, wa.Right, wa.Bottom, scaleForWindow(hwnd))
	if maxW := wa.Right - wa.Left; w > maxW {
		w = maxW
	}
	if maxH := wa.Bottom - wa.Top; h > maxH {
		h = maxH
	}
	x, y := r.Left, r.Top
	if x+w > wa.Right {
		x = wa.Right - w
	}
	if y+h > wa.Bottom {
		y = wa.Bottom - h
	}
	if x < wa.Left {
		x = wa.Left
	}
	if y < wa.Top {
		y = wa.Top
	}
	if x == r.Left && y == r.Top && w == r.Right-r.Left && h == r.Bottom-r.Top {
		return
	}
	procSetWindowPos.Call(uintptr(hwnd), 0, uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		swpNoZOrder|swpNoActivate)
}

// SetWindowPos z-order handles and flags.
const (
	hwndTopmost   = ^uintptr(0)     // HWND_TOPMOST   (-1)
	hwndNoTopmost = ^uintptr(0) - 1 // HWND_NOTOPMOST (-2)
	swpNoSize     = 0x0001
	swpNoMove     = 0x0002
	swpShowWindow = 0x0040
)

// raiseOnce puts a window at the top of the z-order ONCE, without pinning it
// there and without taking keyboard focus — exactly what a freshly opened
// window gets, and nothing more. The next click anywhere sends it behind
// again.
//
// Why not SetForegroundWindow: Windows refuses it from a background process,
// so a pairing window raised by a PHONE (nobody at the PC asked for it) opened
// underneath whatever the user was working in — a full-screen terminal,
// Settings — and "the PC shows nothing" was the report, with the code sitting
// there unseen. Why not HWND_TOPMOST left on: that pins the window over
// everything until closed, which the owner explicitly did not want. Z-order
// moves are not subject to the foreground lock, so TOPMOST immediately
// followed by NOTOPMOST lands the window on top of the stack and leaves it
// an ordinary window.
func raiseOnce(hwnd windows.Handle) {
	flags := uintptr(swpNoMove | swpNoSize | swpNoActivate | swpShowWindow)
	procSetWindowPos.Call(uintptr(hwnd), hwndTopmost, 0, 0, 0, 0, flags)
	procSetWindowPos.Call(uintptr(hwnd), hwndNoTopmost, 0, 0, 0, 0, flags)
}

// flashTaskbar asks for attention the way Windows itself wants background
// apps to: the taskbar button flashes until the user looks. A pairing window
// that a PHONE raised — nobody at the PC asked for it — cannot take the
// foreground (Windows refuses SetForegroundWindow from a background process),
// and forcing it on top of whatever the user is doing is not the answer either.
func flashTaskbar(hwnd windows.Handle) {
	type flashInfo struct {
		size    uint32
		hwnd    uintptr
		flags   uint32
		count   uint32
		timeout uint32
	}
	const flashwTray, flashwTimerNoFG = 0x00000002, 0x0000000C
	fi := flashInfo{hwnd: uintptr(hwnd), flags: flashwTray | flashwTimerNoFG}
	fi.size = uint32(unsafe.Sizeof(fi))
	procFlashWindowEx.Call(uintptr(unsafe.Pointer(&fi)))
}

func clampMinSize(hwnd windows.Handle, lParam uintptr, designW, designH int) {
	if lParam == 0 {
		return
	}
	scale := scaleForWindow(hwnd)
	w := int32(float64(designW)*scale + 0.5)
	h := int32(float64(designH)*scale + 0.5)
	r := rect{Left: 0, Top: 0, Right: w, Bottom: h}
	style := uintptr(wsCaption | wsSysMenu | wsThickFrame | wsMinimizeBox)
	if procAdjustWindowRectExForDpi.Find() == nil {
		procAdjustWindowRectExForDpi.Call(uintptr(unsafe.Pointer(&r)), style, 0, 0,
			uintptr(scale*96+0.5))
	} else {
		procAdjustWindowRect.Call(uintptr(unsafe.Pointer(&r)), style, 0)
	}
	mmi := (*minMaxInfo)(unsafe.Pointer(lParam))
	mmi.MinTrackSize.X = r.Right - r.Left
	mmi.MinTrackSize.Y = r.Bottom - r.Top
}

// workArea is the desktop minus the taskbar, falling back to the full screen.
func workArea() rect {
	var r rect
	const spiGetWorkArea = 0x0030
	if ok, _, _ := procSystemParametersInfo.Call(spiGetWorkArea, 0,
		uintptr(unsafe.Pointer(&r)), 0); ok != 0 && r.Right > r.Left {
		return r
	}
	sw, _, _ := procGetSystemMetricsO.Call(smCXScreenO)
	sh, _, _ := procGetSystemMetricsO.Call(smCYScreenO)
	return rect{Left: 0, Top: 0, Right: int32(sw), Bottom: int32(sh)}
}
