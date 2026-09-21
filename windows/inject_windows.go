//go:build windows

package main

import (
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32              = windows.NewLazySystemDLL("user32.dll")
	procSendInput       = user32.NewProc("SendInput")
	procVkKeyScanW      = user32.NewProc("VkKeyScanW")
	procMapVirtualKeyW  = user32.NewProc("MapVirtualKeyW")
	procSetCursorPos    = user32.NewProc("SetCursorPos")
	procGetSystemMetric = user32.NewProc("GetSystemMetrics")
)

// GetSystemMetrics indices for the primary monitor's pixel size.
const (
	smCXScreen = 0 // primary monitor width  in pixels
	smCYScreen = 1 // primary monitor height in pixels
	// Virtual desktop = the union of every monitor. Its origin is NEGATIVE when
	// a display sits left of / above the primary one, which is why the clamp
	// cannot just be (0,0)-(primaryW,primaryH).
	smXVirtualScreen  = 76
	smYVirtualScreen  = 77
	smCXVirtualScreen = 78
	smCYVirtualScreen = 79
)

const (
	inputMouse    = 0
	inputKeyboard = 1

	keyeventfExtended = 0x0001
	keyeventfKeyup    = 0x0002
	keyeventfUnicode  = 0x0004

	// MapVirtualKey translation: virtual key -> scan code.
	mapvkVKToVSC = 0

	mouseeventfMove       = 0x0001
	mouseeventfLeftDown   = 0x0002
	mouseeventfLeftUp     = 0x0004
	mouseeventfRightDown  = 0x0008
	mouseeventfRightUp    = 0x0010
	mouseeventfMiddleDown = 0x0020
	mouseeventfMiddleUp   = 0x0040
	mouseeventfWheel      = 0x0800
	mouseeventfHWheel     = 0x1000
	wheelDelta            = 120

	vkShift   = 0x10
	vkControl = 0x11
	vkMenu    = 0x12 // Alt
	vkLWin    = 0x5B
)

// INPUT (x64) is 40 bytes: DWORD type + 4 pad + 32-byte union. Both layouts
// below are padded to exactly 40 so SendInput's cbSize is consistent.
type kbInput struct {
	inputType   uint32
	_           uint32
	wVk         uint16
	wScan       uint16
	dwFlags     uint32
	time        uint32
	dwExtraInfo uintptr
	_           [8]byte
}

type mouseInput struct {
	inputType   uint32
	_           uint32
	dx          int32
	dy          int32
	mouseData   uint32
	dwFlags     uint32
	time        uint32
	dwExtraInfo uintptr
}

// Modifier keys currently held down on this host (bitmask of mod* constants).
var heldMask int
var leftDown, rightDown bool

// The INPUT buffers handed to SendInput are PACKAGE-LEVEL, not stack locals.
//
// `procSendInput.Call(..., uintptr(unsafe.Pointer(&in)), ...)` launders a
// pointer through uintptr in our own frame. The compiler only guarantees the
// pointee stays put when that conversion appears directly in a recognised
// syscall's argument list; through LazyProc.Call it does not, so the goroutine's
// stack may be copied (growth) between taking the address and the kernel reading
// it — and the address then refers to a slot a LATER call has since reused.
//
// The visible symptom was typing: "Hello Remotype 12345" arrived as
// "Hello Remotype 55555", earlier characters in a fast run collapsing onto the
// last one, and pacing the sends changed the corruption instead of removing it.
// Globals live outside the stack and are never relocated.
var (
	inputMu  sync.Mutex
	kbBuf    kbInput
	mouseBuf mouseInput
)

// The "extended" half of the keyboard: the grey navigation island, the numpad's
// Enter and Divide, and the right-hand modifiers. Windows distinguishes these
// from their numpad twins by ONE flag — without KEYEVENTF_EXTENDEDKEY, VK_LEFT
// is delivered as numpad-4, VK_HOME as numpad-7, VK_DELETE as numpad-period. With
// NumLock on, that is not a dead key: it types a digit. macOS has no such split,
// which is exactly why arrows and Home/End in a macro behaved on the Mac and
// misfired here.
var extendedVK = map[uint16]bool{
	0x21: true, // VK_PRIOR   page up
	0x22: true, // VK_NEXT    page down
	0x23: true, // VK_END
	0x24: true, // VK_HOME
	0x25: true, // VK_LEFT
	0x26: true, // VK_UP
	0x27: true, // VK_RIGHT
	0x28: true, // VK_DOWN
	0x2D: true, // VK_INSERT
	0x2E: true, // VK_DELETE
	0x6F: true, // VK_DIVIDE  numpad /
	0x90: true, // VK_NUMLOCK
	0xA3: true, // VK_RCONTROL
	0xA5: true, // VK_RMENU   right Alt / AltGr
}

// scanFor fills wScan for a virtual-key event. Plenty of software reads the scan
// code rather than the virtual key — games and anything on raw input especially —
// and a keystroke arriving with wScan 0 is silently dropped by those.
func scanFor(vk uint16) uint16 {
	res, _, _ := procMapVirtualKeyW.Call(uintptr(vk), uintptr(mapvkVKToVSC))
	return uint16(res)
}

func sendKbd(vk, scan uint16, flags uint32) {
	inputMu.Lock()
	defer inputMu.Unlock()
	kbBuf = kbInput{inputType: inputKeyboard, wVk: vk, wScan: scan, dwFlags: flags}
	procSendInput.Call(1, uintptr(unsafe.Pointer(&kbBuf)), unsafe.Sizeof(kbBuf))
}

func sendMouse(dx, dy int32, data uint32, flags uint32) {
	inputMu.Lock()
	defer inputMu.Unlock()
	mouseBuf = mouseInput{inputType: inputMouse, dx: dx, dy: dy, mouseData: data, dwFlags: flags}
	procSendInput.Call(1, uintptr(unsafe.Pointer(&mouseBuf)), unsafe.Sizeof(mouseBuf))
}

// vkEvent builds one virtual-key event with its scan code and, where the key
// needs it, the extended flag. Every VK press in this file goes through here so
// none can be built without them.
func vkEvent(vk uint16, up bool) kbInput {
	flags := uint32(0)
	if extendedVK[vk] {
		flags |= keyeventfExtended
	}
	if up {
		flags |= keyeventfKeyup
	}
	return kbInput{inputType: inputKeyboard, wVk: vk, wScan: scanFor(vk), dwFlags: flags}
}

func sendVK(vk uint16, up bool) {
	e := vkEvent(vk, up)
	sendKbd(e.wVk, e.wScan, e.dwFlags)
}

func keyTap(vk uint16) {
	sendVK(vk, false)
	sendVK(vk, true)
}

func unicodeTap(r rune) {
	if r > 0xFFFF {
		return // BMP only
	}
	sendKbd(0, uint16(r), keyeventfUnicode)
	sendKbd(0, uint16(r), keyeventfUnicode|keyeventfKeyup)
}

func modVK(bit int) uint16 {
	switch bit {
	case modCtrl:
		return vkControl
	case modShift:
		return vkShift
	case modAlt:
		return vkMenu
	case modGUI:
		return vkLWin
	}
	return 0
}

// setModifierHeld presses/releases a real modifier key so chords like Alt+Tab
// (hold Alt, tap Tab, release Alt) work like a physical keyboard.
func setModifierHeld(bit int, down bool) {
	vk := modVK(bit)
	if vk == 0 {
		return
	}
	if down {
		heldMask |= bit
		sendVK(vk, false)
	} else {
		heldMask &^= bit
		sendVK(vk, true)
	}
}

// withMods presses the transient (latched) modifiers from mods that aren't
// already held, runs f, then releases them.
func withMods(mods int, f func()) {
	var applied []uint16
	for _, b := range []int{modCtrl, modShift, modAlt, modGUI} {
		if mods&b != 0 && heldMask&b == 0 {
			vk := modVK(b)
			sendVK(vk, false)
			applied = append(applied, vk)
		}
	}
	f()
	for i := len(applied) - 1; i >= 0; i-- {
		sendVK(applied[i], true)
	}
}

func vkKeyScan(r rune) (vk uint16, shift, ok bool) {
	res, _, _ := procVkKeyScanW.Call(uintptr(uint16(r)))
	v := uint16(res)
	if v == 0xFFFF {
		return 0, false, false
	}
	return v & 0xFF, (v>>8)&1 != 0, true
}

func shortcutActive(mods int) bool {
	return (mods|heldMask)&(modCtrl|modAlt|modGUI) != 0
}

// Characters that are really KEYS. Injecting them as Unicode is what macOS's
// injector deliberately does not do either — its charKey table maps "\n" to the
// Return keycode and "\t" to Tab. On Windows a KEYEVENTF_UNICODE event carrying
// U+000A is simply ignored by almost every app: no newline, no Enter, nothing.
// That is why Enter "worked on the Mac" and vanished here, both for a typed
// Return and for every line break inside a pasted or typed-out block.
var charAsVK = map[rune]uint16{
	'\n': 0x0D, // VK_RETURN
	'\r': 0x0D,
	'\t': 0x09, // VK_TAB
}

func typeChar(c string, mods int) {
	r := firstRune(c)
	if r == 0 {
		return
	}
	if vk, ok := charAsVK[r]; ok {
		withMods(mods, func() { keyTap(vk) })
		return
	}
	// For shortcuts (Ctrl/Alt/Win + key) we need the virtual key; for plain
	// typing, Unicode injection reproduces the exact character on any layout.
	if shortcutActive(mods) {
		if vk, shift, ok := vkKeyScan(r); ok {
			extra := mods
			if shift {
				extra |= modShift
			}
			withMods(extra, func() { keyTap(vk) })
			return
		}
	}
	unicodeTap(r)
}

// typeString injects a whole string as ONE batched SendInput per chunk, with
// each character's key-down and key-up adjacent in the same array.
//
// Typing it character by character meant two separate SendInput calls each, and
// in a fast run those interleave in the raw input queue: runs of characters
// collapse onto the last one ("Hello Remotype 12345" landing as
// "Hello Remotype 55555"). Pacing the calls hid it without fixing it. A single
// call is atomic with respect to the queue, and is also far less work than 2N
// transitions into the kernel.
func typeString(s string) {
	runes := make([]rune, 0, len(s))
	var prev rune
	for _, r := range s {
		// CRLF is ONE line break. Both halves map to VK_RETURN, so passing the
		// pair through would press Enter twice and double-space the paste.
		if r == '\n' && prev == '\r' {
			prev = r
			continue
		}
		prev = r
		if r <= 0xFFFF { // BMP only, as unicodeTap had it
			runes = append(runes, r)
		}
	}
	if len(runes) == 0 {
		return
	}
	// Chunked with a small gap, as cheap insurance for apps that drain the raw
	// input queue slowly. The gap is negligible (a 200-character paste costs
	// ~12 ms) and typing still runs thousands of characters a second.
	//
	// KNOWN LIMITATION, measured not guessed: the Windows 11 XAML Notepad
	// collapses the tail of injected text onto its last character — "Hello
	// Remotype 12345 abcdefgh" appears as "Hello Remotype hhhhhhhhhhhhhh".
	// The same string typed into a classic Win32 control (the Win+R dialog) is
	// byte-perfect, so the injection itself is correct and this is that app's
	// input stack. Pacing down to 16 characters per 6 ms did NOT fix it, which
	// is why this is documented rather than papered over.
	const perCall = 64
	const chunkGap = 4 * time.Millisecond
	for start := 0; start < len(runes); start += perCall {
		end := start + perCall
		if end > len(runes) {
			end = len(runes)
		}
		// Heap-allocated: a slice's backing array is never relocated by stack
		// growth, unlike the locals the single-event path used to pass.
		evts := make([]kbInput, 0, (end-start)*2)
		for _, r := range runes[start:end] {
			// A line break inside the block is a real Return, for the same
			// reason a typed one is: Unicode U+000A injects nothing. Kept in
			// the SAME batch so the atomicity that fixed the collapsing-text
			// bug still covers the whole chunk.
			if vk, ok := charAsVK[r]; ok {
				evts = append(evts, vkEvent(vk, false), vkEvent(vk, true))
				continue
			}
			evts = append(evts,
				kbInput{inputType: inputKeyboard, wScan: uint16(r), dwFlags: keyeventfUnicode},
				kbInput{inputType: inputKeyboard, wScan: uint16(r), dwFlags: keyeventfUnicode | keyeventfKeyup},
			)
		}
		inputMu.Lock()
		procSendInput.Call(uintptr(len(evts)), uintptr(unsafe.Pointer(&evts[0])),
			unsafe.Sizeof(evts[0]))
		inputMu.Unlock()
		if end < len(runes) {
			time.Sleep(chunkGap)
		}
	}
}

var namedVK = map[string]uint16{
	"tab": 0x09, "enter": 0x0D, "return": 0x0D, "backspace": 0x08, "space": 0x20,
	"esc": 0x1B, "escape": 0x1B, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
	"home": 0x24, "end": 0x23, "fdel": 0x2E,
	"f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74, "f6": 0x75,
	"f7": 0x76, "f8": 0x77, "f9": 0x78, "f10": 0x79, "f11": 0x7A, "f12": 0x7B,
	// Keypad cluster (Numpad mode) — genuine numpad VKs so spreadsheets see a
	// real numeric keypad, not the number row. kpenter shares VK_RETURN (0x0D).
	"kp0": 0x60, "kp1": 0x61, "kp2": 0x62, "kp3": 0x63, "kp4": 0x64,
	"kp5": 0x65, "kp6": 0x66, "kp7": 0x67, "kp8": 0x68, "kp9": 0x69,
	"kpdot": 0x6E, "kpplus": 0x6B, "kpminus": 0x6D, "kpmul": 0x6A,
	"kpdiv": 0x6F, "kpenter": 0x0D,
}

func pressNamed(name string, mods int) {
	vk, ok := namedVK[name]
	if !ok {
		return
	}
	withMods(mods, func() { keyTap(vk) })
}

// moveMouse applies a relative delta by WARPING the cursor to the computed
// absolute position, deliberately NOT via SendInput's relative move.
//
// A relative MOUSEEVENTF_MOVE is fed through Windows pointer ballistics
// (acceleration + "Enhance pointer precision"), so the same finger travel
// covered a different distance here than on macOS — which warps absolutely
// (Injector.swift: currentPos() + dx) and never touches an acceleration curve.
// Worse for feel: ballistics scale DOWN small deltas, so slow, careful movement
// under-travelled and read as laggy, while fast flicks overshot.
//
// Sub-pixel remainders are carried in `mouseFrac` rather than truncated, so a
// long slow drag does not silently lose distance one rounding at a time.
var mouseFracX, mouseFracY float64

func moveMouse(dx, dy int) {
	var p struct{ X, Y int32 }
	if r, _, _ := procGetCursorPos.Call(uintptr(unsafe.Pointer(&p))); r == 0 {
		// Cursor unreadable (secure desktop / no session) — fall back to the
		// relative path rather than dropping the movement entirely.
		sendMouse(int32(dx), int32(dy), 0, mouseeventfMove)
		return
	}
	tx := float64(p.X) + float64(dx) + mouseFracX
	ty := float64(p.Y) + float64(dy) + mouseFracY
	nx, ny := int32(tx), int32(ty)
	mouseFracX, mouseFracY = tx-float64(nx), ty-float64(ny)

	warpCursorAbs(nx, ny)
}

// warpCursorAbs puts the cursor at an absolute physical-pixel point, clamped to
// the virtual desktop. Shared by the relative moveMouse path and by tv.point.
//
// It resets moveMouse's carried sub-pixel remainder: that fraction describes a
// journey from the OLD position, and an absolute warp makes it meaningless — left
// alone it would smear up to a pixel of stale motion into the next relative move.
func warpCursorAbs(nx, ny int32) {
	vx, _, _ := procGetSystemMetric.Call(uintptr(smXVirtualScreen))
	vy, _, _ := procGetSystemMetric.Call(uintptr(smYVirtualScreen))
	vw, _, _ := procGetSystemMetric.Call(uintptr(smCXVirtualScreen))
	vh, _, _ := procGetSystemMetric.Call(uintptr(smCYVirtualScreen))
	if vw > 0 && vh > 0 {
		x0, y0 := int32(vx), int32(vy)
		x1, y1 := x0+int32(vw)-1, y0+int32(vh)-1
		if nx < x0 {
			nx = x0
		}
		if ny < y0 {
			ny = y0
		}
		if nx > x1 {
			nx = x1
		}
		if ny > y1 {
			ny = y1
		}
	}
	mouseFracX, mouseFracY = 0, 0
	procSetCursorPos.Call(uintptr(nx), uintptr(ny))
}

// moveCursorNormalized warps the REAL cursor to a normalized (0..1, top-left,
// y-down) point on the PRIMARY monitor — Spotlight's "aim first" phase. Uses
// SetCursorPos in absolute screen pixels (GetSystemMetrics gives the primary
// monitor size), not the relative SendInput move path.
func moveCursorNormalized(nx, ny float64) {
	w, _, _ := procGetSystemMetric.Call(uintptr(smCXScreen)) // primary width  (px)
	h, _, _ := procGetSystemMetric.Call(uintptr(smCYScreen)) // primary height (px)
	if w == 0 || h == 0 {
		return
	}
	nx = clamp01(nx)
	ny = clamp01(ny)
	px := int32(nx * float64(int32(w)))
	py := int32(ny * float64(int32(h)))
	// SetCursorPos(x, y) — absolute virtual-screen coordinates, primary origin
	// at top-left.
	procSetCursorPos.Call(uintptr(px), uintptr(py))
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func mouseButton(b int, down bool, mods int) {
	withMods(mods, func() {
		var flag uint32
		switch b {
		case 1:
			if down {
				flag = mouseeventfRightDown
				rightDown = true
			} else {
				flag = mouseeventfRightUp
				rightDown = false
			}
		case 2:
			if down {
				flag = mouseeventfMiddleDown
			} else {
				flag = mouseeventfMiddleUp
			}
		default:
			if down {
				flag = mouseeventfLeftDown
				leftDown = true
			} else {
				flag = mouseeventfLeftUp
				leftDown = false
			}
		}
		sendMouse(0, 0, 0, flag)
	})
}

func scrollWheel(dx, dy int) {
	if dy != 0 {
		sendMouse(0, 0, uint32(int32(dy*wheelDelta)), mouseeventfWheel)
	}
	if dx != 0 {
		sendMouse(0, 0, uint32(int32(dx*wheelDelta)), mouseeventfHWheel)
	}
}

// zoom — Ctrl+wheel, the Windows convention for zooming in most apps.
func zoom(d int) {
	withMods(modCtrl, func() {
		sendMouse(0, 0, uint32(int32(d*wheelDelta)), mouseeventfWheel)
	})
}

var mediaVK = map[string]uint16{
	"playpause": 0xB3, "next": 0xB0, "prev": 0xB1,
	"mute": 0xAD, "volup": 0xAF, "voldown": 0xAE,
}

func consumer(u string) {
	// Brightness has no media virtual-key on Windows — drive DDC/CI instead
	// (brightness_windows.go). ffwd/rewind (in-track scrub) has no Windows key
	// either and the deck already carries next/prev, so it stays a no-op here
	// (SMTC seek is a future item).
	switch u {
	case "brightup":
		adjustBrightness(+brightnessStep)
		return
	case "brightdown":
		adjustBrightness(-brightnessStep)
		return
	}
	if vk, ok := mediaVK[u]; ok {
		keyTap(vk)
	}
}

func releaseAllModifiers() {
	for _, b := range []int{modCtrl, modShift, modAlt, modGUI} {
		if heldMask&b != 0 {
			sendVK(modVK(b), true)
		}
	}
	heldMask = 0
	if leftDown {
		sendMouse(0, 0, 0, mouseeventfLeftUp)
		leftDown = false
	}
	if rightDown {
		sendMouse(0, 0, 0, mouseeventfRightUp)
		rightDown = false
	}
}

func firstRune(s string) rune {
	for _, r := range s {
		return r
	}
	return 0
}
