//go:build windows

// The pairing window — the one moment where a human, at the PC, decides that a
// particular phone is allowed to type on it.
//
// Same construction as the About window (about_windows.go): a small native
// modal painted by hand, pinned to the app's dark Flow palette, running its own
// message loop on a goroutine pinned with runtime.LockOSThread. It differs in
// two ways that matter:
//
//   - It repaints on a one-second timer, because the code has a visible
//     countdown. A pairing code with no deadline on screen is a code people
//     leave up all afternoon.
//   - It can be raised from the NETWORK goroutine, the instant a phone sends
//     pair.begin. That is the ordinary first run: the user taps Pair on the
//     phone before finding the tray menu.
package main

import (
	"runtime"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	procSetTimer       = user32o.NewProc("SetTimer")
	procKillTimer      = user32o.NewProc("KillTimer")
	procInvalidateRect = user32o.NewProc("InvalidateRect")
)

const (
	wmTimer = 0x0113

	dtLeft      = 0x00000000
	dtWordBreak = 0x00000010

	pairingTimerID = 1
)

var (
	pairingMu   sync.Mutex
	pairingHwnd windows.Handle
	pairingOnce sync.Once
	// Recomputed on every paint, so the click test can never disagree with what
	// was drawn.
	pairingCloseRect rect
)

// showPairingWindow raises the window, minting a code if none is live. Safe to
// call from any goroutine, and safe to call repeatedly: a second call while a
// code is showing brings the same code forward rather than invalidating the one
// the user is halfway through typing.
func showPairingWindow() {
	if pairing.live() == "" {
		pairing.show()
	}

	pairingMu.Lock()
	hwnd := pairingHwnd
	pairingMu.Unlock()
	if hwnd != 0 {
		procSetForegroundWindow.Call(uintptr(hwnd))
		fitIntoWorkArea(hwnd)
		raiseOnce(hwnd)
		flashTaskbar(hwnd)
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return
	}
	go pairingWindowLoop()
}

func pairingWindowLoop() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	prepAboutContent() // shares the palette and the wordmark bitmap

	hInst, _, _ := procGetModuleHandleW.Call(0)
	className := windows.StringToUTF16Ptr("RemotypePairWnd")
	pairingOnce.Do(func() {
		cursor, _, _ := procLoadCursorW.Call(0, uintptr(idcArrow))
		appIcon, _, _ := procLoadIconW.Call(hInst, 1)
		appIconSm, _, _ := procLoadImageW.Call(hInst, 1, 1 /*IMAGE_ICON*/, 16, 16, 0)
		wc := wndClassExW{
			WndProc:   windows.NewCallback(pairingWndProc),
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
		uintptr(unsafe.Pointer(windows.StringToUTF16Ptr("Pair a phone"))),
		uintptr(wsCaption|wsSysMenu|wsThickFrame|wsMinimizeBox|wsVisible),
		uintptr(cwUseDefault), uintptr(cwUseDefault), uintptr(cwUseDefault), uintptr(cwUseDefault),
		0, 0, hInst, 0,
	)
	if hwnd == 0 {
		return
	}
	// The code is READ OFF THIS WINDOW and typed on a phone, so it has to be
	// big and it has to be legible at whatever the display's scaling is.
	sizeWindowForClient(windows.Handle(hwnd), 760, 620)
	fitIntoWorkArea(windows.Handle(hwnd))
	pairingMu.Lock()
	pairingHwnd = windows.Handle(hwnd)
	pairingMu.Unlock()

	procSetTimer.Call(hwnd, pairingTimerID, 1000, 0)
	procSetForegroundWindow.Call(hwnd)
	procShowWindow.Call(hwnd, swShowNormal)
	raiseOnce(windows.Handle(hwnd))
	flashTaskbar(windows.Handle(hwnd))
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

	pairingMu.Lock()
	pairingHwnd = 0
	pairingMu.Unlock()
}

func pairingWndProc(hwnd windows.Handle, message uint32, wParam, lParam uintptr) uintptr {
	switch message {
	case wmEraseBkgnd:
		// Claim it. The paint below covers every pixel, and letting Windows
		// wipe the background first is the other half of the flicker.
		return 1
	case wmPaint:
		pairingPaint(hwnd)
		return 0
	case wmTimer:
		// The countdown ticks and the "paired with…" state can arrive from the
		// network goroutine, so the window redraws itself rather than waiting
		// to be told.
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmSize:
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmGetMinMaxInfo:
		clampMinSize(hwnd, lParam, 620, 520)
		return 0
	case wmDpiChanged:
		if lParam != 0 {
			r := (*rect)(unsafe.Pointer(lParam))
			procSetWindowPos.Call(uintptr(hwnd), 0,
				uintptr(r.Left), uintptr(r.Top),
				uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top),
				swpNoZOrder|swpNoActivate)
			fitIntoWorkArea(windows.Handle(hwnd))
		}
		procInvalidateRect.Call(uintptr(hwnd), 0, 0)
		return 0
	case wmLButtonDown:
		x := int32(int16(lParam & 0xFFFF))
		y := int32(int16((lParam >> 16) & 0xFFFF))
		// Always live. It used to be disabled until a phone had completed the
		// handshake — "the button must not say done while the answer is no" —
		// which left a window nobody could dismiss when the phone never came,
		// and a live code sitting on screen for ten minutes. Close means
		// close; closing before a phone paired retires the code (wmClose).
		if inRect(pairingCloseRect, x, y) {
			procPostMessageW.Call(uintptr(hwnd), wmClose, 0, 0)
		}
		return 0
	case wmClose:
		if open, _ := hostSessionOpen(); !open {
			pairing.retire("window closed before a phone paired")
		}
		procKillTimer.Call(uintptr(hwnd), pairingTimerID)
		procDestroyWindow.Call(uintptr(hwnd))
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(message), wParam, lParam)
	return r
}

// groupCode spaces the twelve characters in threes of four. It is read off a
// screen and typed on a phone, so legibility beats density — and Crockford
// base32 has already removed the character pairs no font can save.
// groupCode renders the code as three groups of four joined by HYPHENS.
//
// Spaces were worse than they look: someone reading "9SP8  V69P  1XZY" cannot
// tell whether the gap is one space or three, or whether it is part of the code
// at all — and the phone's field shows hyphens. Both ends print the same
// characters now, so what is on the screen is exactly what gets typed.
//
// It strips the separators FIRST, because rt1GenerateCode already returns a
// hyphenated code — regrouping the hyphenated form produced "9SP8 -V69 -P1X ZY".
func groupCode(code string) string {
	var bare []byte
	for i := 0; i < len(code); i++ {
		c := code[i]
		if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			bare = append(bare, c)
		}
	}
	var parts []string
	for i := 0; i < len(bare); i += 4 {
		end := i + 4
		if end > len(bare) {
			end = len(bare)
		}
		parts = append(parts, string(bare[i:end]))
	}
	return strings.Join(parts, "-")
}

func pairingPaint(hwnd windows.Handle) {
	u, rc := beginPaint(hwnd)
	defer u.endPaint()
	hdc := u.hdc

	cw := rc.Right - rc.Left
	pad := u.px(38)
	contentW := cw - pad*2

	u.fill(rc, aboutBG)
	procSetBkMode.Call(hdc, bkTransparent)

	titleFont := u.font(30, fwBold)
	codeFont := u.font(62, fwBold)
	bodyFont := u.font(19, fwNormal)
	smallFont := u.font(16, fwNormal)

	centred := uintptr(dtCenter | dtVCenter | dtSingleLine)
	wrap := uintptr(dtLeft | dtWordBreak)

	connected, connectedName := hostSessionOpen()

	y := u.px(34)
	u.text("Pair a phone", titleFont, aboutFG,
		rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(38)}, centred)
	y += u.px(46)
	// The subtitle is an instruction until it is done, then it is the result.
	// Leaving "type this code on the phone" up after the phone has connected
	// leaves the user looking for something still to do.
	subtitle := "Type this code on the phone, once."
	if pairing.statusMessage() != "" && !connected {
		subtitle = "Pairing did not finish."
	}
	subtitleColor := aboutMuted
	if connected {
		subtitle = "Connected successfully"
		subtitleColor = colorref(0x34, 0xC7, 0x59)
		if connectedName != "" {
			subtitle = "Connected successfully — " + connectedName
		}
	}
	u.text(subtitle, bodyFont, subtitleColor,
		rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(28)}, centred)
	y += u.px(48)

	switch {
	case pairing.paired() != "":
		u.text("Paired with "+pairing.paired(), titleFont, aboutFG,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(40)}, centred)
		y += u.px(50)
		body := "This phone can connect from now on without a code. You can remove it from the tray menu at any time."
		h := u.textHeight(body, bodyFont, contentW)
		u.text(body, bodyFont, aboutMuted,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + h}, wrap)
		y += h + u.px(24)

	case pairing.statusMessage() != "":
		// The ceremony ended on the phone's side. Say what happened where the
		// code used to be; "type this code" over a code that is gone is worse
		// than no window at all.
		u.text(pairing.statusMessage(), titleFont, aboutFG,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(40)}, centred)
		y += u.px(50)
		body := "Nothing was paired. Tap this PC on the phone again, or choose \"Pair a phone\" in the tray menu, for a new code."
		h := u.textHeight(body, bodyFont, contentW)
		u.text(body, bodyFont, aboutMuted,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + h}, wrap)
		y += h + u.px(24)

	case pairing.live() != "":
		// The code gets a card of its own and the biggest type in the app: it
		// is read off this screen, across a room, and typed on a phone.
		cardH := u.px(132)
		card := rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + cardH}
		u.fill(card, colorref(0x0F, 0x13, 0x22))
		u.text(groupCode(pairing.live()), codeFont, aboutFG, card, centred)
		y += cardH + u.px(14)
		u.text(formatCountdown(pairing.secondsRemaining()), smallFont, aboutMuted,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(24)}, centred)
		y += u.px(38)

	default:
		u.text("That code is no longer valid", titleFont, aboutFG,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + u.px(38)}, centred)
		y += u.px(48)
		body := "Codes last ten minutes, and retire after three wrong tries. Choose \"Pair a phone\" in the tray menu for a new one."
		h := u.textHeight(body, bodyFont, contentW)
		u.text(body, bodyFont, aboutMuted,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + h}, wrap)
		y += h + u.px(24)
	}

	// The Close button, pinned to the bottom and drawn before the body so the
	// body knows where it must stop.
	btnH := u.px(46)
	btnW := u.px(180)
	btnY := rc.Bottom - pad - btnH
	pairingCloseRect = rect{Left: (cw - btnW) / 2, Top: btnY, Right: (cw + btnW) / 2, Bottom: btnY + btnH}
	if connected {
		u.button("Close", bodyFont, pairingCloseRect,
			colorref(0x30, 0x49, 0xE0), colorref(0xFF, 0xFF, 0xFF))
	} else {
		// Greyed, and it does nothing if clicked. A window whose only button is
		// live before the job is done invites people to shut it mid-ceremony.
		u.button("Close", bodyFont, pairingCloseRect,
			colorref(0x16, 0x1A, 0x2A), colorref(0x6A, 0x72, 0x8C))
	}

	// Said plainly, because the honest answer to "is this safe?" is the reason
	// the ceremony exists at all.
	for _, line := range []string{
		"Only someone who can see this screen can pair a phone.",
		"After pairing, everything between phone and PC is encrypted.",
		"A phone that is not paired cannot type, click, or read your clipboard.",
	} {
		h := u.textHeight(line, smallFont, contentW)
		// Stop rather than draw over the button. The minimum window size makes
		// this hard to reach, but a longer translation could.
		if y+h > btnY-u.px(16) {
			break
		}
		u.text(line, smallFont, aboutMuted,
			rect{Left: pad, Top: y, Right: cw - pad, Bottom: y + h}, wrap)
		y += h + u.px(12)
	}

}

func formatCountdown(secs int) string {
	if secs <= 0 {
		return "Expired"
	}
	m := secs / 60
	s := secs % 60
	return "Valid for " + itoa2(m) + ":" + pad2(s)
}

func itoa2(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa2(n)
	}
	return itoa2(n)
}
