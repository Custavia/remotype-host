//go:build windows

// The setup wizard — the Windows half of the same idea as the Mac's.
//
// What it is guiding is different, though, and worth being clear about. macOS
// has two permission switches to find in System Settings; Windows has none. Its
// one gate is the firewall, and specifically the "Windows Security Alert" dialog
// that appears the first time the host binds its port. **Cancel on that dialog
// does not mean "later" — it writes a persistent BLOCK rule**, after which the
// host runs perfectly, reports itself healthy, and is unreachable forever with
// nothing on screen saying why. See firewall_windows.go.
//
// So this wizard has two steps: show the user what that dialog looks like and
// what to click, with a repair button for the case where they already clicked
// Cancel — and then WAIT FOR A PHONE. That second step is the whole point.
// Nothing on this machine can be asked whether a block rule exists (netsh's
// output is localized, and the COM policy API is a long way from here for one
// boolean), but a phone that got a connection through has answered the question
// the firewall step was really asking. It is also a better check than the
// firewall rules would be: rules can be perfect while the PC is on the wrong
// network, behind AP isolation, or on a VPN, and every one of those looks
// identical from the tray.
package main

import (
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

const setupTimerID = 2

var (
	setupMu   sync.Mutex
	setupHwnd windows.Handle
	setupOnce sync.Once
	// Which step is showing. Advanced by the user, or by a phone arriving.
	setupStep int
)

// showSetupWizard raises the window. Safe from any goroutine.
func showSetupWizard() {
	setupMu.Lock()
	hwnd := setupHwnd
	setupMu.Unlock()
	if hwnd != 0 {
		procSetForegroundWindow.Call(uintptr(hwnd))
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return
	}
	go setupWindowLoop()
}

func setupWindowLoop() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	prepAboutContent() // shares the palette

	hInst, _, _ := procGetModuleHandleW.Call(0)
	className := windows.StringToUTF16Ptr("RemotypeSetupWnd")
	setupOnce.Do(func() {
		cursor, _, _ := procLoadCursorW.Call(0, uintptr(idcArrow))
		appIcon, _, _ := procLoadIconW.Call(hInst, 1)
		appIconSm, _, _ := procLoadImageW.Call(hInst, 1, 1 /*IMAGE_ICON*/, 16, 16, 0)
		wc := wndClassExW{
			WndProc:   windows.NewCallback(setupWndProc),
			Instance:  windows.Handle(hInst),
			Cursor:    windows.Handle(cursor),
			Icon:      windows.Handle(appIcon),
			IconSm:    windows.Handle(appIconSm),
			ClassName: className,
		}
		wc.Size = uint32(unsafe.Sizeof(wc))
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	})

	// Resizable, with a minimise box: a fixed 560x600 was the other half of the
	// "buttons barely usable" report — when the layout does not fit, the user's
	// only recourse is to make the window bigger, and they could not.
	hwnd, _, _ := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("Set up Remotype Host"))),
		uintptr(wsCaption|wsSysMenu|wsThickFrame|wsMinimizeBox|wsVisible),
		uintptr(cwUseDefault), uintptr(cwUseDefault), uintptr(cwUseDefault), uintptr(cwUseDefault),
		0, 0, hInst, 0,
	)
	if hwnd == 0 {
		return
	}
	// Design size in 100 %-scaling pixels; sizeWindowForClient does the DPI and
	// the non-client margins, which is what the old code got wrong.
	sizeWindowForClient(windows.Handle(hwnd), setupDesignW, setupDesignH)
	setupMu.Lock()
	setupHwnd = windows.Handle(hwnd)
	setupMu.Unlock()

	// A phone can arrive at any moment on the network goroutine; repaint when
	// it does, so step 2 turns green on its own exactly as the Mac's does.
	setupOnChange(func() {
		setupMu.Lock()
		h := setupHwnd
		setupMu.Unlock()
		if h != 0 {
			procInvalidateRect.Call(uintptr(h), 0, 0)
		}
	})

	procSetTimer.Call(hwnd, setupTimerID, 700, 0)
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

	setupOnChange(nil)
	setupMu.Lock()
	setupHwnd = 0
	setupMu.Unlock()
}

// Hit rectangles for the two painted buttons, recomputed on every paint so the
// click test can never disagree with what was drawn.
var (
	setupPrimaryRect rect
	setupNextRect    rect
)

func setupWndProc(hwnd windows.Handle, message uint32, wParam, lParam uintptr) uintptr {
	switch message {
	case wmEraseBkgnd:
		// Claim it. The paint below covers every pixel, and letting Windows
		// wipe the background first is the other half of the flicker.
		return 1
	case wmPaint:
		setupPaint(hwnd)
		return 0
	case wmTimer:
		// Step 1 advances by itself the moment a phone gets through — the same
		// "it turns green without you asking" the Mac wizard has.
		if reached, _ := setupPhoneReached(); reached && setupStep == 0 {
			setupStep = 1
		}
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmLButtonDown:
		x := int32(int16(lParam & 0xFFFF))
		y := int32(int16((lParam >> 16) & 0xFFFF))
		setupClick(hwnd, x, y)
		return 0
	case wmSize:
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmGetMinMaxInfo:
		clampMinSize(hwnd, lParam, 640, 620)
		return 0
	case wmDpiChanged:
		// Moving to a monitor with different scaling: take the rect Windows
		// suggests, then repaint at the new scale.
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
		procKillTimer.Call(uintptr(hwnd), setupTimerID)
		procDestroyWindow.Call(uintptr(hwnd))
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

func inRect(r rect, x, y int32) bool {
	return x >= r.Left && x <= r.Right && y >= r.Top && y <= r.Bottom
}

func setupClick(hwnd windows.Handle, x, y int32) {
	switch setupStep {
	case 0:
		if inRect(setupPrimaryRect, x, y) {
			if err := repairFirewall(); err != nil {
				logf("firewall repair could not start: %v", err)
			}
			return
		}
		if inRect(setupNextRect, x, y) {
			setupStep = 1
			procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		}
	case 1:
		if inRect(setupPrimaryRect, x, y) {
			showPairingWindow()
			return
		}
		if inRect(setupNextRect, x, y) {
			procPostMessageW.Call(uintptr(hwnd), wmClose, 0, 0)
		}
	}
}

const (
	wmLButtonDown = 0x0201

	// The window's design size, in 100 %-scaling pixels. Generous on purpose:
	// this is the first thing a new user sees, and the previous 560x600 was
	// reported as cramped, small-text and hard to click on a scaled display.
	setupDesignW = 720
	setupDesignH = 660
)

// setupPaint lays the page out from the CLIENT rect downward, measuring every
// block of prose instead of guessing its height, and pins the buttons to the
// bottom. That is what makes the window resizable and what stops text from
// landing underneath a button when a string changes length.
func setupPaint(hwnd windows.Handle) {
	u, rc := beginPaint(hwnd)
	defer u.endPaint()
	hdc := u.hdc

	cw := rc.Right - rc.Left
	ch := rc.Bottom - rc.Top
	pad := u.px(36)
	contentW := cw - pad*2

	u.fill(rc, aboutBG)
	procSetBkMode.Call(hdc, bkTransparent)

	titleFont := u.font(27, fwBold)
	headFont := u.font(17, fwBold)
	bodyFont := u.font(16, fwNormal)
	smallFont := u.font(14, fwNormal)

	centred := uintptr(dtCenter | dtVCenter | dtSingleLine)
	wrap := uintptr(dtLeft | dtWordBreak)

	reached, phoneName := setupPhoneReached()

	// ---- header
	y := u.px(30)
	u.text("Set up Remotype Host", titleFont, aboutFG,
		rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(38)}, wrap)
	y += u.px(42)
	stepLine := "Step 1 of 2  ·  Let your phone reach this PC"
	if setupStep == 1 {
		stepLine = "Step 2 of 2  ·  Connect your phone"
	}
	u.text(stepLine, smallFont, aboutMuted,
		rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(24)}, wrap)
	y += u.px(38)
	u.fill(rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(1)}, colorref(0x23, 0x2A, 0x42))
	y += u.px(28)

	// ---- buttons first: they are pinned to the bottom, and everything above
	// gets the space that is left.
	btnH := u.px(46)
	btnY := ch - pad - btnH
	primaryW := u.px(260)
	setupPrimaryRect = rect{Left: pad, Top: btnY, Right: pad + primaryW, Bottom: btnY + btnH}
	nextW := u.px(150)
	setupNextRect = rect{Left: cw - pad - nextW, Top: btnY, Right: cw - pad, Bottom: btnY + btnH}

	primary := "Repair firewall access"
	nextLabel := "Next"
	if setupStep == 1 {
		primary = "Show a pairing code"
		nextLabel = "Done"
	}
	u.button(primary, headFont, setupPrimaryRect, colorref(0x30, 0x49, 0xE0), colorref(0xFF, 0xFF, 0xFF))
	u.button(nextLabel, headFont, setupNextRect, colorref(0x16, 0x1A, 0x2A), aboutFG)

	// ---- the live strip, just above the buttons
	stripH := u.px(60)
	stripY := btnY - u.px(22) - stripH
	strip := rect{Left: pad, Top: stripY, Right: cw - pad, Bottom: stripY + stripH}
	u.fill(strip, colorref(0x0F, 0x13, 0x22))
	dotS := u.px(12)
	dotX := pad + u.px(20)
	dotY := stripY + (stripH-dotS)/2
	msg := "Waiting for a phone — this turns green on its own."
	dotColor := colorref(0x3D, 0x5B, 0xFF)
	if reached {
		dotColor = colorref(0x34, 0xC7, 0x59)
		msg = "A phone reached this PC — the network is fine."
		if phoneName != "" {
			msg = phoneName + " reached this PC — the network is fine."
		}
	}
	u.fill(rect{Left: dotX, Top: dotY, Right: dotX + dotS, Bottom: dotY + dotS}, dotColor)
	u.text(msg, bodyFont, aboutFG,
		rect{Left: dotX + dotS + u.px(16), Top: stripY, Right: cw - pad, Bottom: stripY + stripH},
		dtLeft|dtVCenter|dtSingleLine)

	// ---- the words, measured so nothing overlaps
	var lead, note string
	if setupStep == 0 {
		lead = "The first time Remotype Host opens its port, Windows asks whether to allow it. Click \"Allow access\"."
		note = "Clicking Cancel on that box does not mean \"later\" — it blocks this program for good, and nothing afterwards says so. Remotype Host only listens for phones on your Wi-Fi; it never connects to the internet. If that already happened, repair it below."
	} else {
		lead = "Open Remotype on your phone and tap this PC in the list. The first time, it asks for a pairing code — this PC shows it."
		note = "Both devices must be on the same Wi-Fi. Internet is not required — nothing you type or show ever leaves your network. If the list stays empty, go back a step and repair firewall access."
	}
	leadH := u.textHeight(lead, bodyFont, contentW)
	noteH := u.textHeight(note, smallFont, contentW)
	textTop := stripY - u.px(26) - noteH - u.px(14) - leadH
	// A very short window would push the prose up into the header. The minimum
	// track size makes that hard to reach, but a 3-line translation could still
	// do it — so clamp rather than overlap.
	if textTop < y {
		textTop = y
	}

	// ---- illustration fills what is left between header and text
	illoTop := y
	illoBottom := textTop - u.px(26)
	// The caption and the recessed well eat vertical space, so the floor is
	// higher than it was: below this the drawing is not worth the room.
	if illoBottom-illoTop > u.px(190) {
		if setupStep == 0 {
			paintSecurityAlertMock(u, cw, illoTop, illoBottom, headFont, bodyFont, smallFont)
		} else {
			paintPhoneLinkMock(u, cw, illoTop, illoBottom, bodyFont, reached)
		}
	}

	u.text(lead, bodyFont, aboutFG,
		rect{Left: pad, Top: textTop, Right: cw - pad, Bottom: textTop + leadH}, wrap)
	u.text(note, smallFont, aboutMuted,
		rect{Left: pad, Top: textTop + leadH + u.px(14), Right: cw - pad,
			Bottom: textTop + leadH + u.px(14) + noteH}, wrap)

	_ = centred
}

// A stylised "Windows Security Alert" — the box people meet once and answer
// wrong. Deliberately a mock, not a facsimile: the user's copy is in their
// language and their Windows version's chrome, and a screenshot of ours would be
// wrong on both counts. It has to say "the left button, not the right one".
//
// It is also LABELLED as a picture, and that is not decoration. The first
// version looked enough like a real dialog that people tried to click its
// buttons — which do nothing, so the wizard silently appeared broken at the
// exact moment it was trying to teach something. It now sits behind a caption
// and a corner tag, inset on a recessed panel, so it reads as an example of
// what Windows will show rather than something to act on.
func paintSecurityAlertMock(u *uiCtx, cw, top, bottom int32, headFont, bodyFont, smallFont uintptr) {
	leftMidCap := uintptr(dtLeft | dtVCenter | dtSingleLine)
	capH := u.px(26)
	u.text("EXAMPLE  ·  this is what Windows will show you — do not click here",
		smallFont, colorref(0x6A, 0x72, 0x8C),
		rect{Left: u.px(36), Top: top, Right: cw - u.px(36), Bottom: top + capH}, leftMidCap)
	top += capH + u.px(8)

	// A recessed well behind the mock, so the illustration is visibly a picture
	// sitting ON the page rather than part of it.
	well := rect{Left: u.px(36), Top: top, Right: cw - u.px(36), Bottom: bottom}
	u.fill(well, colorref(0x08, 0x0B, 0x14))

	inset := u.px(70)
	card := rect{Left: inset, Top: top + u.px(14), Right: cw - inset, Bottom: bottom - u.px(14)}
	u.fill(card, colorref(0x16, 0x1A, 0x2A))
	titleH := u.px(34)
	u.fill(rect{Left: card.Left, Top: card.Top, Right: card.Right, Bottom: card.Top + titleH},
		colorref(0x1D, 0x22, 0x36))
	leftMid := uintptr(dtLeft | dtVCenter | dtSingleLine)
	centred := uintptr(dtCenter | dtVCenter | dtSingleLine)

	u.text("Windows Security Alert", smallFont, aboutMuted,
		rect{Left: card.Left + u.px(14), Top: card.Top, Right: card.Right - u.px(14),
			Bottom: card.Top + titleH}, leftMid)
	// A tag ON the artwork, because the caption above it is easy to skip past.
	tagW, tagH := u.px(74), u.px(20)
	u.tag("EXAMPLE", smallFont, rect{
		Left: card.Right - u.px(14) - tagW, Top: card.Top + (titleH-tagH)/2,
		Right: card.Right - u.px(14), Bottom: card.Top + (titleH-tagH)/2 + tagH})

	y := card.Top + titleH + u.px(18)
	u.text("Allow Remotype Host to communicate on these networks?", bodyFont, aboutFG,
		rect{Left: card.Left + u.px(22), Top: y, Right: card.Right - u.px(22), Bottom: y + u.px(26)}, leftMid)

	y += u.px(34)
	for _, label := range []string{"Private networks (home or work)", "Public networks"} {
		box := rect{Left: card.Left + u.px(22), Top: y + u.px(3),
			Right: card.Left + u.px(38), Bottom: y + u.px(19)}
		u.fill(box, colorref(0x34, 0xC7, 0x59))
		u.text(label, smallFont, aboutMuted,
			rect{Left: card.Left + u.px(48), Top: y, Right: card.Right - u.px(22), Bottom: y + u.px(24)}, leftMid)
		y += u.px(30)
	}

	// The whole point of the drawing: which button to press.
	btnH := u.px(38)
	btnY := card.Bottom - u.px(20) - btnH
	cancel := rect{Left: card.Right - u.px(22) - u.px(120), Top: btnY,
		Right: card.Right - u.px(22), Bottom: btnY + btnH}
	allow := rect{Left: cancel.Left - u.px(16) - u.px(160), Top: btnY,
		Right: cancel.Left - u.px(16), Bottom: btnY + btnH}
	ring := rect{Left: allow.Left - u.px(4), Top: allow.Top - u.px(4),
		Right: allow.Right + u.px(4), Bottom: allow.Bottom + u.px(4)}
	u.fill(ring, colorref(0x3D, 0x5B, 0xFF))
	u.button("Allow access", headFont, allow, colorref(0x30, 0x49, 0xE0), colorref(0xFF, 0xFF, 0xFF))
	u.fill(cancel, colorref(0x23, 0x2A, 0x42))
	u.text("Cancel", bodyFont, colorref(0x9A, 0xA3, 0xC2), cancel, centred)
}

// tagRect draws a small corner label on an illustration.
func (u *uiCtx) tag(text string, font uintptr, at rect) {
	u.fill(at, colorref(0x3D, 0x5B, 0xFF))
	u.text(text, font, colorref(0xFF, 0xFF, 0xFF), at, dtCenter|dtVCenter|dtSingleLine)
}

// Phone → PC, with the link lit once something has actually arrived.
func paintPhoneLinkMock(u *uiCtx, cw, top, bottom int32, bodyFont uintptr, reached bool) {
	// Same treatment as the alert mock: a recessed well so the drawing reads as
	// a picture rather than as controls.
	well := rect{Left: u.px(36), Top: top, Right: cw - u.px(36), Bottom: bottom}
	u.fill(well, colorref(0x08, 0x0B, 0x14))

	inset := u.px(70)
	card := rect{Left: inset, Top: top + u.px(14), Right: cw - inset, Bottom: bottom - u.px(14)}
	u.fill(card, colorref(0x16, 0x1A, 0x2A))

	mid := (card.Top + card.Bottom) / 2
	phone := rect{Left: card.Left + u.px(70), Top: mid - u.px(62),
		Right: card.Left + u.px(146), Bottom: mid + u.px(62)}
	u.fill(phone, colorref(0x0B, 0x0E, 0x1A))
	u.fill(rect{Left: phone.Left + u.px(7), Top: phone.Top + u.px(12),
		Right: phone.Right - u.px(7), Bottom: phone.Bottom - u.px(12)}, colorref(0x3D, 0x5B, 0xFF))

	pc := rect{Left: card.Right - u.px(216), Top: mid - u.px(54),
		Right: card.Right - u.px(70), Bottom: mid + u.px(36)}
	u.fill(pc, colorref(0x0B, 0x0E, 0x1A))
	u.fill(rect{Left: pc.Left + u.px(10), Top: pc.Top + u.px(10),
		Right: pc.Right - u.px(10), Bottom: pc.Bottom - u.px(10)}, colorref(0x1D, 0x22, 0x36))
	stand := (pc.Left + pc.Right) / 2
	u.fill(rect{Left: stand - u.px(32), Top: pc.Bottom, Right: stand + u.px(32),
		Bottom: pc.Bottom + u.px(12)}, colorref(0x0B, 0x0E, 0x1A))

	linkColor := colorref(0x23, 0x2A, 0x42)
	label := "Not connected yet"
	if reached {
		linkColor = colorref(0x34, 0xC7, 0x59)
		label = "Connected"
	}
	u.fill(rect{Left: phone.Right + u.px(18), Top: mid - u.px(3),
		Right: pc.Left - u.px(18), Bottom: mid + u.px(3)}, linkColor)

	u.text(label, bodyFont, aboutMuted,
		rect{Left: card.Left, Top: card.Bottom - u.px(42), Right: card.Right,
			Bottom: card.Bottom - u.px(12)}, dtCenter|dtVCenter|dtSingleLine)
}
