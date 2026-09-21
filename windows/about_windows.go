//go:build windows

// A proper Custavia-branded About window for the Windows host — a small native
// modal (title bar + close box) that paints the Custavia wordmark plus the app
// details, in place of a plain MessageBox. Theme-aware: cream in light mode,
// warm ink in dark mode (read from the system AppsUseLightTheme setting).
//
// It reuses the Win32 bindings + structs already declared in overlay_windows.go
// (same package): the window class, message loop, DIB, and GDI procs. Only the
// paint-side procs (BeginPaint / DrawText / fonts / StretchDIBits) are new here.
//
// Threading mirrors the overlay: a Win32 message loop is thread-affine, so the
// window runs on its own goroutine pinned with runtime.LockOSThread. Built +
// cross-checked only; no Windows box available here to verify at runtime.

package main

import (
	"bytes"
	_ "embed"
	"image"
	"image/draw"
	"image/png"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed remotype-wordmark.png
var wordmarkLightPNG []byte // the Remotype lockup (mark + wordmark)

//go:embed remotype-wordmark.png
var wordmarkDarkPNG []byte // same lockup — the companion is pinned to the dark theme

// ---- extra Win32 bindings (the shared ones live in overlay_windows.go) ----
var (
	procBeginPaint          = user32o.NewProc("BeginPaint")
	procEndPaint            = user32o.NewProc("EndPaint")
	procGetClientRect       = user32o.NewProc("GetClientRect")
	procDrawTextW           = user32o.NewProc("DrawTextW")
	procLoadIconW           = user32o.NewProc("LoadIconW")
	procLoadImageW          = user32o.NewProc("LoadImageW")
	procFillRect            = user32o.NewProc("FillRect")
	procPostQuitMessage     = user32o.NewProc("PostQuitMessage")
	procUpdateWindow        = user32o.NewProc("UpdateWindow")
	procSetForegroundWindow = user32o.NewProc("SetForegroundWindow")

	procCreateFontW       = gdi32.NewProc("CreateFontW")
	procSetTextColor      = gdi32.NewProc("SetTextColor")
	procSetBkMode         = gdi32.NewProc("SetBkMode")
	procCreateSolidBrush  = gdi32.NewProc("CreateSolidBrush")
	procSetStretchBltMode = gdi32.NewProc("SetStretchBltMode")
	procStretchDIBits     = gdi32.NewProc("StretchDIBits")
)

const (
	wmPaint = 0x000F
	wmClose = 0x0010

	wsCaption = 0x00C00000
	wsSysMenu = 0x00080000
	wsVisible = 0x10000000

	dtCenter     = 0x00000001
	dtVCenter    = 0x00000004
	dtSingleLine = 0x00000020
	dtNoPrefix   = 0x00000800

	bkTransparent  = 1
	cleartypeQual  = 5
	defaultCharset = 1
	halftoneMode   = 4
	srcCopy        = 0x00CC0020

	fwNormal = 400
	fwBold   = 700
)

type rect struct{ Left, Top, Right, Bottom int32 }

type paintStruct struct {
	Hdc         uintptr
	FErase      int32
	RcPaint     rect
	FRestore    int32
	FIncr       int32
	RgbReserved [32]byte
}

// Window content, set before the window is created and read by the paint proc
// (only one About window paints at a time).
var (
	aboutLogoBits  []byte
	aboutLogoW     int32
	aboutLogoH     int32
	aboutBG        uintptr // COLORREF background
	aboutFG        uintptr // primary text
	aboutMuted     uintptr // secondary text
	aboutAccent    uintptr // the support email
	aboutClassOnce sync.Once
)

func colorref(r, g, b byte) uintptr { return uintptr(r) | uintptr(g)<<8 | uintptr(b)<<16 }

// systemUsesLightTheme reads HKCU AppsUseLightTheme (1 = light, 0 = dark).
func systemUsesLightTheme() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return true
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("AppsUseLightTheme")
	if err != nil {
		return true
	}
	return v != 0
}

// prepAboutContent decodes the right wordmark, flattens it onto the theme
// background (so the transparent areas seam seamlessly), and sets the palette.
func prepAboutContent() {
	// Pinned to the app's DARK "Flow" palette regardless of the Windows theme —
	// that blue-black IS the product's home screen, and a window that flipped to
	// cream on a light PC would read as a different app next to the phone.
	// Every value below was MEASURED against the background for >=6:1 (Custavia
	// rule): fg 17.0:1, muted 7.7:1, accent 7.4:1.
	bgR, bgG, bgB := byte(0x0B), byte(0x0E), byte(0x1A)
	raw := wordmarkDarkPNG
	aboutBG = colorref(0x0B, 0x0E, 0x1A)
	aboutFG = colorref(0xEE, 0xF1, 0xFB)
	aboutMuted = colorref(0x9A, 0xA3, 0xC2)
	aboutAccent = colorref(0x9F, 0xB6, 0xFF)

	img, err := png.Decode(bytes.NewReader(raw))
	if err != nil {
		aboutLogoBits = nil
		return
	}
	b := img.Bounds()
	nr := image.NewNRGBA(b)
	draw.Draw(nr, b, img, b.Min, draw.Src)
	w, h := b.Dx(), b.Dy()
	aboutLogoW, aboutLogoH = int32(w), int32(h)

	// Top-down 32bpp BGRA, alpha flattened onto the theme bg → opaque for SRCCOPY.
	buf := make([]byte, w*h*4)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			s := nr.PixOffset(b.Min.X+x, b.Min.Y+y)
			r, g, bl, a := nr.Pix[s], nr.Pix[s+1], nr.Pix[s+2], nr.Pix[s+3]
			af := uint32(a)
			ia := 255 - af
			o := (y*w + x) * 4
			buf[o+0] = byte((uint32(bl)*af + uint32(bgB)*ia) / 255)
			buf[o+1] = byte((uint32(g)*af + uint32(bgG)*ia) / 255)
			buf[o+2] = byte((uint32(r)*af + uint32(bgR)*ia) / 255)
			buf[o+3] = 255
		}
	}
	aboutLogoBits = buf
}

// showAboutWindow builds + runs the branded About modal. Blocks (its own message
// loop) until the window is closed; call it on its own goroutine.
func showAboutWindow() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	prepAboutContent()

	hInst, _, _ := procGetModuleHandleW.Call(0)
	className := windows.StringToUTF16Ptr("RemotypeAboutWnd")
	aboutClassOnce.Do(func() {
		cursor, _, _ := procLoadCursorW.Call(0, uintptr(idcArrow))
		// The app icon, from the resource embedded in the binary
		// (rsrc_windows_amd64.syso). Without this the class icon is zero and
		// Windows falls back to its generic application icon in the title bar —
		// which is what the About window was showing.
		appIcon, _, _ := procLoadIconW.Call(hInst, 1) // IDI = 1, first icon
		appIconSm, _, _ := procLoadImageW.Call(hInst, 1,
			1 /*IMAGE_ICON*/, 16, 16, 0)
		wc := wndClassExW{
			WndProc:   windows.NewCallback(aboutWndProc),
			Instance:  windows.Handle(hInst),
			Cursor:    windows.Handle(cursor),
			Icon:      windows.Handle(appIcon),
			IconSm:    windows.Handle(appIconSm),
			ClassName: className,
		}
		wc.Size = uint32(unsafe.Sizeof(wc))
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	})

	hwnd, _, _ := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("About Remotype Host"))),
		uintptr(wsCaption|wsSysMenu|wsThickFrame|wsMinimizeBox|wsVisible),
		uintptr(cwUseDefault), uintptr(cwUseDefault), uintptr(cwUseDefault), uintptr(cwUseDefault),
		0, 0, hInst, 0,
	)
	if hwnd == 0 {
		return
	}
	// Design size at 100 % scaling; sizeWindowForClient applies the monitor's
	// DPI and the non-client margins. The old fixed 470x400 was both too small
	// and, on a scaled display, two-thirds of even that.
	sizeWindowForClient(windows.Handle(hwnd), 560, 520)
	procSetForegroundWindow.Call(hwnd)
	procShowWindow.Call(hwnd, swShowNormal)
	procUpdateWindow.Call(hwnd)

	var msg winMsg
	for {
		ret, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}
}

func aboutWndProc(hwnd windows.Handle, message uint32, wParam, lParam uintptr) uintptr {
	switch message {
	case wmEraseBkgnd:
		// Claim it. The paint below covers every pixel, and letting Windows
		// wipe the background first is the other half of the flicker.
		return 1
	case wmPaint:
		aboutPaint(hwnd)
		return 0
	case wmSize:
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmGetMinMaxInfo:
		clampMinSize(hwnd, lParam, 470, 430)
		return 0
	case wmDpiChanged:
		if lParam != 0 {
			r := (*rect)(unsafe.Pointer(lParam))
			procSetWindowPos.Call(uintptr(hwnd), 0,
				uintptr(r.Left), uintptr(r.Top),
				uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top),
				swpNoZOrder|swpNoActivate)
		}
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmClose:
		procDestroyWindow.Call(uintptr(hwnd))
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

func newFont(px, weight int32) uintptr {
	f, _, _ := procCreateFontW.Call(
		uintptr(int32(-px)), 0, 0, 0, uintptr(weight), 0, 0, 0,
		defaultCharset, 0, 0, cleartypeQual, 0,
		uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("Segoe UI"))),
	)
	return f
}

func aboutPaint(hwnd windows.Handle) {
	u, rc := beginPaint(hwnd)
	defer u.endPaint()
	hdc := u.hdc

	cw := rc.Right - rc.Left
	u.fill(rc, aboutBG)
	procSetBkMode.Call(hdc, bkTransparent)

	titleFont := u.font(26, fwBold)
	bodyFont := u.font(17, fwNormal)
	smallFont := u.font(15, fwNormal)
	centred := uintptr(dtCenter | dtVCenter | dtSingleLine)

	line := func(text string, font, color uintptr, top, height int32) {
		u.text(text, font, color, rect{Left: u.px(24), Top: top, Right: cw - u.px(24),
			Bottom: top + height}, centred)
	}

	// Logo (wordmark) — scaled to fit, centred near the top.
	yPos := u.px(38)
	if aboutLogoBits != nil && aboutLogoW > 0 {
		lw := u.px(320)
		if lw > cw-u.px(80) {
			lw = cw - u.px(80)
		}
		lh := lw * aboutLogoH / aboutLogoW
		lx := (cw - lw) / 2
		bi := bitmapInfoHeader{
			Size:        uint32(unsafe.Sizeof(bitmapInfoHeader{})),
			Width:       aboutLogoW,
			Height:      -aboutLogoH, // top-down
			Planes:      1,
			BitCount:    32,
			Compression: biRGB,
		}
		procSetStretchBltMode.Call(hdc, halftoneMode)
		procStretchDIBits.Call(hdc,
			uintptr(lx), uintptr(yPos), uintptr(lw), uintptr(lh),
			0, 0, uintptr(aboutLogoW), uintptr(aboutLogoH),
			uintptr(unsafe.Pointer(&aboutLogoBits[0])),
			uintptr(unsafe.Pointer(&bi)), dibRGBColors, srcCopy,
		)
		yPos += lh + u.px(34)
	} else {
		yPos = u.px(70)
	}

	line(appName, titleFont, aboutFG, yPos, u.px(36))
	yPos += u.px(42)
	line("Version "+appVersion+"  ·  Released "+appReleaseDate, smallFont, aboutMuted, yPos, u.px(26))
	yPos += u.px(48)
	line("Developed by "+appCompany, bodyFont, aboutFG, yPos, u.px(28))
	yPos += u.px(38)
	line("Contact us at:", smallFont, aboutMuted, yPos, u.px(24))
	yPos += u.px(28)
	line(appSupport, bodyFont, aboutAccent, yPos, u.px(28))
	yPos += u.px(40)
	line("Wi-Fi: required  ·  Internet: never", smallFont, aboutMuted, yPos, u.px(24))
	yPos += u.px(26)
	line("Remotype Host talks only to devices on your network.", smallFont, aboutMuted, yPos, u.px(24))

}
