//go:build linux

// uinput injector for the Linux Remotype host.
//
// We create a single virtual input device that reports BOTH keyboard keys and
// relative-pointer events (REL_X/Y/WHEEL/HWHEEL + the three mouse buttons), then
// stream `struct input_event` writes to it. Because uinput lives in the kernel,
// the synthetic events flow through evdev exactly like a real USB keyboard/mouse
// would — so they reach BOTH X11 and Wayland compositors (libinput reads evdev),
// which is the entire reason this host exists.
//
// All the Linux input-event-code / ioctl constants are hardcoded below (from
// <linux/input-event-codes.h> and <linux/uinput.h>) so we don't depend on cgo
// headers being present on the build machine. uinput's ABI for these is stable.
//
// VALIDATED 2026-09-17: keymap_linux_test.go creates this device for real,
// injects every printable ASCII character and every named key, reads the events
// back off the resulting /dev/input/eventN, and decodes them through an
// independent copy of the kernel's US keymap. All 95 printable characters and
// every named key resolve correctly, and no modifier is left held. Run it with:
//
//	GOOS=linux go test -c -o /tmp/keymap.test . &&
//	docker run --rm --privileged -v /tmp/keymap.test:/t:ro alpine /t -test.v
//
// Still unvalidated, and NOT covered by that test: behaviour under a real
// desktop session (does the compositor accept the virtual device), non-US
// keyboard layouts, and X11 vs Wayland differences. Those need a desktop.
package main

import (
	"unsafe"

	"golang.org/x/sys/unix"
)

// ---- EV_* event types (linux/input-event-codes.h) ----
const (
	evSyn = 0x00
	evKey = 0x01
	evRel = 0x02
)

// ---- SYN_* (linux/input-event-codes.h) ----
const synReport = 0x00

// ---- REL_* relative axes (linux/input-event-codes.h) ----
const (
	relX      = 0x00
	relY      = 0x01
	relHWheel = 0x06
	relWheel  = 0x08
)

// ---- BTN_* mouse buttons (linux/input-event-codes.h) ----
const (
	btnLeft   = 0x110
	btnRight  = 0x111
	btnMiddle = 0x112
)

// ---- KEY_* codes we use (linux/input-event-codes.h) ----
const (
	keyEsc        = 1
	key1          = 2
	key2          = 3
	key3          = 4
	key4          = 5
	key5          = 6
	key6          = 7
	key7          = 8
	key8          = 9
	key9          = 10
	key0          = 11
	keyMinus      = 12
	keyEqual      = 13
	keyBackspace  = 14
	keyTab        = 15
	keyQ          = 16
	keyW          = 17
	keyE          = 18
	keyR          = 19
	keyT          = 20
	keyY          = 21
	keyU          = 22
	keyI          = 23
	keyO          = 24
	keyP          = 25
	keyLeftBrace  = 26 // [
	keyRightBrace = 27 // ]
	keyEnter      = 28
	keyLeftCtrl   = 29
	keyA          = 30
	keyS          = 31
	keyD          = 32
	keyF          = 33
	keyG          = 34
	keyH          = 35
	keyJ          = 36
	keyK          = 37
	keyL          = 38
	keySemicolon  = 39 // ;
	keyApostrophe = 40 // '
	keyGrave      = 41 // `
	keyLeftShift  = 42
	keyBackslash  = 43 // \
	keyZ          = 44
	keyX          = 45
	keyC          = 46
	keyV          = 47
	keyB          = 48
	keyN          = 49
	keyM          = 50
	keyComma      = 51 // ,
	keyDot        = 52 // .
	keySlash      = 53 // /
	keyRightShift = 54
	keyKpAsterisk = 55
	keyLeftAlt    = 56
	keySpace      = 57

	keyF1  = 59
	keyF2  = 60
	keyF3  = 61
	keyF4  = 62
	keyF5  = 63
	keyF6  = 64
	keyF7  = 65
	keyF8  = 66
	keyF9  = 67
	keyF10 = 68

	keyKp7            = 71
	keyKp8            = 72
	keyKp9            = 73
	keyKpMinus        = 74
	keyKp4            = 75
	keyKp5            = 76
	keyKp6            = 77
	keyKpPlus         = 78
	keyKp1            = 79
	keyKp2            = 80
	keyKp3            = 81
	keyKp0            = 82
	keyKpDot          = 83
	keyF11            = 87
	keyF12            = 88
	keyKpEnter        = 96
	keyRightCtrl      = 97
	keyKpSlash        = 98
	keyRightAlt       = 100
	keyHome           = 102
	keyUpArrow        = 103
	keyLeft           = 105
	keyRight          = 106
	keyEnd            = 107
	keyDownArrow      = 108
	keyDelete         = 111 // forward-delete (the "fdel" name)
	keyMute           = 113
	keyVolumeDown     = 114
	keyVolumeUp       = 115
	keyLeftMeta       = 125 // Super / GUI
	keyNextSong       = 163
	keyPlayPause      = 164
	keyPreviousSong   = 165
	keyBrightnessDown = 224
	keyBrightnessUp   = 225
)

// ---- uinput ioctls (linux/uinput.h) ----
// These _IOW/_IO numbers come straight from <linux/uinput.h>: UI_DEV_CREATE is
// _IO('U',1), UI_DEV_DESTROY _IO('U',2), the SET_*BIT calls are _IOW('U',n,int),
// and UI_DEV_SETUP is _IOW('U',3, struct uinput_setup).
const (
	uiSetEvBit   = 0x40045564 // _IOW('U',100,int)
	uiSetKeyBit  = 0x40045565 // _IOW('U',101,int)
	uiSetRelBit  = 0x40045566 // _IOW('U',102,int)
	uiDevSetup   = 0x405c5503 // _IOW('U',3,struct uinput_setup) — 92-byte arg
	uiDevCreate  = 0x5501     // _IO('U',1)
	uiDevDestroy = 0x5502     // _IO('U',2)

	busUSB = 0x03
)

// inputEvent mirrors `struct input_event`. On modern 64-bit kernels the
// timeval is two 64-bit longs (16 bytes), giving a 24-byte struct. We leave the
// time fields zero — the kernel timestamps events for us.
type inputEvent struct {
	Sec   int64
	Usec  int64
	Type  uint16
	Code  uint16
	Value int32
}

// uinputSetup mirrors `struct uinput_setup` from <linux/uinput.h>:
//
//	struct input_id id;        // 4 x __u16 = 8 bytes
//	char name[UINPUT_MAX_NAME_SIZE]; // 80 bytes
//	__u32 ff_effects_max;      // 4 bytes
//
// Total 92 bytes — matches the 0x5c in the uiDevSetup ioctl number.
type uinputSetup struct {
	BusType uint16
	Vendor  uint16
	Product uint16
	Version uint16
	Name    [80]byte
	FFMax   uint32
}

var uinputFD int = -1

// heldMask is the set of modifier bits we're currently holding down (so chords
// like Super+Tab work: hold Super, tap Tab, release Super).
var heldMask int
var leftDown, rightDown bool

func ioctl(fd int, req uint, arg uintptr) error {
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uintptr(req), arg)
	if errno != 0 {
		return errno
	}
	return nil
}

// injectInit opens /dev/uinput and configures the virtual keyboard+mouse.
func injectInit() error {
	fd, err := unix.Open("/dev/uinput", unix.O_WRONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}

	// 1) Declare which event TYPES this device emits: keys, relative motion, sync.
	for _, ev := range []uint{evKey, evRel, evSyn} {
		if err := ioctl(fd, uiSetEvBit, uintptr(ev)); err != nil {
			unix.Close(fd)
			return err
		}
	}

	// 2) Declare every relative axis we move.
	for _, rel := range []uint{relX, relY, relWheel, relHWheel} {
		if err := ioctl(fd, uiSetRelBit, uintptr(rel)); err != nil {
			unix.Close(fd)
			return err
		}
	}

	// 3) Declare every key/button we can ever emit. The kernel rejects EV_KEY
	//    events for codes that weren't registered here, so this list must be a
	//    superset of everything the keymaps below produce — plus the modifiers
	//    and the three mouse buttons.
	for _, key := range allUsedKeys() {
		if err := ioctl(fd, uiSetKeyBit, uintptr(key)); err != nil {
			unix.Close(fd)
			return err
		}
	}
	for _, btn := range []uint{btnLeft, btnRight, btnMiddle} {
		if err := ioctl(fd, uiSetKeyBit, uintptr(btn)); err != nil {
			unix.Close(fd)
			return err
		}
	}

	// 4) Name + USB-ish ids, then UI_DEV_SETUP + UI_DEV_CREATE to instantiate.
	setup := uinputSetup{BusType: busUSB, Vendor: 0x1209, Product: 0x7479, Version: 1}
	copy(setup.Name[:], "Remotype Virtual Input")
	if err := ioctl(fd, uiDevSetup, uintptr(unsafe.Pointer(&setup))); err != nil {
		unix.Close(fd)
		return err
	}
	if err := ioctl(fd, uiDevCreate, 0); err != nil {
		unix.Close(fd)
		return err
	}

	uinputFD = fd
	return nil
}

// injectClose tears the virtual device down on shutdown.
func injectClose() {
	if uinputFD < 0 {
		return
	}
	_ = ioctl(uinputFD, uiDevDestroy, 0)
	_ = unix.Close(uinputFD)
	uinputFD = -1
}

// emit writes one input_event to the uinput fd.
func emit(typ, code uint16, value int32) {
	if uinputFD < 0 {
		return
	}
	ev := inputEvent{Type: typ, Code: code, Value: value}
	b := (*[unsafe.Sizeof(ev)]byte)(unsafe.Pointer(&ev))[:]
	_, _ = unix.Write(uinputFD, b)
}

// syn flushes a packet of events — every logical action ends with SYN_REPORT
// so the kernel processes the batch atomically.
func syn() { emit(evSyn, synReport, 0) }

// keyDown / keyUp push a single key transition (no syn — caller batches).
func keyDown(code uint16) { emit(evKey, code, 1) }
func keyUp(code uint16)   { emit(evKey, code, 0) }

// tap presses then releases a key within one report.
func tap(code uint16) {
	keyDown(code)
	keyUp(code)
	syn()
}

// ---- modifier handling ----

func modKey(bit int) uint16 {
	switch bit {
	case modCtrl:
		return keyLeftCtrl
	case modShift:
		return keyLeftShift
	case modAlt:
		return keyLeftAlt
	case modGUI:
		return keyLeftMeta
	}
	return 0
}

// setModifierHeld presses/releases a real modifier so chords like Super+Tab
// (hold Super, tap Tab, release Super) behave like a physical keyboard.
func setModifierHeld(bit int, down bool) {
	code := modKey(bit)
	if code == 0 {
		return
	}
	if down {
		heldMask |= bit
		keyDown(code)
	} else {
		heldMask &^= bit
		keyUp(code)
	}
	syn()
}

// withMods presses the transient (latched) modifiers from mods that aren't
// already held, runs f, then releases them.
func withMods(mods int, f func()) {
	var applied []uint16
	for _, b := range []int{modCtrl, modShift, modAlt, modGUI} {
		if mods&b != 0 && heldMask&b == 0 {
			code := modKey(b)
			keyDown(code)
			applied = append(applied, code)
		}
	}
	if len(applied) > 0 {
		syn()
	}
	f()
	for i := len(applied) - 1; i >= 0; i-- {
		keyUp(applied[i])
	}
	if len(applied) > 0 {
		syn()
	}
}

// ---- ASCII → (KEY_* code, needs Shift) ----

// asciiKey maps a printable ASCII rune to its US-layout key code and whether
// Shift is required to produce it.
func asciiKey(r rune) (code uint16, shift, ok bool) {
	// Letters.
	if r >= 'a' && r <= 'z' {
		return letterKey[r-'a'], false, true
	}
	if r >= 'A' && r <= 'Z' {
		return letterKey[r-'A'], true, true
	}
	// Digits (unshifted) and their shifted symbols.
	if c, s, found := digitKey(r); found {
		return c, s, true
	}
	// Remaining punctuation / symbols.
	if e, found := symbolKey[r]; found {
		return e.code, e.shift, true
	}
	if r == ' ' {
		return keySpace, false, true
	}
	return 0, false, false
}

var letterKey = [26]uint16{
	keyA, keyB, keyC, keyD, keyE, keyF, keyG, keyH, keyI, keyJ, keyK, keyL, keyM,
	keyN, keyO, keyP, keyQ, keyR, keyS, keyT, keyU, keyV, keyW, keyX, keyY, keyZ,
}

// digitKey covers '0'-'9' and the shifted symbol that shares each digit key.
func digitKey(r rune) (uint16, bool, bool) {
	switch r {
	case '1':
		return key1, false, true
	case '2':
		return key2, false, true
	case '3':
		return key3, false, true
	case '4':
		return key4, false, true
	case '5':
		return key5, false, true
	case '6':
		return key6, false, true
	case '7':
		return key7, false, true
	case '8':
		return key8, false, true
	case '9':
		return key9, false, true
	case '0':
		return key0, false, true
	case '!':
		return key1, true, true
	case '@':
		return key2, true, true
	case '#':
		return key3, true, true
	case '$':
		return key4, true, true
	case '%':
		return key5, true, true
	case '^':
		return key6, true, true
	case '&':
		return key7, true, true
	case '*':
		return key8, true, true
	case '(':
		return key9, true, true
	case ')':
		return key0, true, true
	}
	return 0, false, false
}

type symEntry struct {
	code  uint16
	shift bool
}

// symbolKey maps the remaining US-layout punctuation to (key code, shift?).
var symbolKey = map[rune]symEntry{
	'-':  {keyMinus, false},
	'_':  {keyMinus, true},
	'=':  {keyEqual, false},
	'+':  {keyEqual, true},
	'[':  {keyLeftBrace, false},
	'{':  {keyLeftBrace, true},
	']':  {keyRightBrace, false},
	'}':  {keyRightBrace, true},
	'\\': {keyBackslash, false},
	'|':  {keyBackslash, true},
	';':  {keySemicolon, false},
	':':  {keySemicolon, true},
	'\'': {keyApostrophe, false},
	'"':  {keyApostrophe, true},
	'`':  {keyGrave, false},
	'~':  {keyGrave, true},
	',':  {keyComma, false},
	'<':  {keyComma, true},
	'.':  {keyDot, false},
	'>':  {keyDot, true},
	'/':  {keySlash, false},
	'?':  {keySlash, true},
}

// typeChar types a single character with the given latched mods (Shift is
// inferred from the character itself, e.g. 'A' or '$').
func typeChar(c string, mods int) {
	r := firstRune(c)
	if r == 0 {
		return
	}
	code, shift, ok := asciiKey(r)
	if !ok {
		return // non-ASCII: uinput keycode injection can't reach it on a US map
	}
	extra := mods
	if shift {
		extra |= modShift
	}
	withMods(extra, func() { tap(code) })
}

// typeString types each character of s in turn.
func typeString(s string) {
	for _, r := range s {
		typeChar(string(r), 0)
	}
}

// ---- named keys ----

var namedKey = map[string]uint16{
	"tab": keyTab, "enter": keyEnter, "return": keyEnter, "backspace": keyBackspace,
	"space": keySpace, "esc": keyEsc, "escape": keyEsc,
	"left": keyLeft, "right": keyRight, "up": keyUpArrow, "down": keyDownArrow,
	"home": keyHome, "end": keyEnd, "fdel": keyDelete,
	"f1": keyF1, "f2": keyF2, "f3": keyF3, "f4": keyF4, "f5": keyF5, "f6": keyF6,
	"f7": keyF7, "f8": keyF8, "f9": keyF9, "f10": keyF10, "f11": keyF11, "f12": keyF12,
	// Keypad cluster (Numpad mode) — genuine numpad codes, not the number row.
	"kp0": keyKp0, "kp1": keyKp1, "kp2": keyKp2, "kp3": keyKp3, "kp4": keyKp4,
	"kp5": keyKp5, "kp6": keyKp6, "kp7": keyKp7, "kp8": keyKp8, "kp9": keyKp9,
	"kpdot": keyKpDot, "kpplus": keyKpPlus, "kpminus": keyKpMinus,
	"kpmul": keyKpAsterisk, "kpdiv": keyKpSlash, "kpenter": keyKpEnter,
}

// pressNamed types a named key with the given mods applied verbatim.
func pressNamed(name string, mods int) {
	code, ok := namedKey[name]
	if !ok {
		return // unknown name → safe no-op (older-host semantics)
	}
	withMods(mods, func() { tap(code) })
}

// ---- mouse ----

func moveMouse(dx, dy int) {
	if dx != 0 {
		emit(evRel, relX, int32(dx))
	}
	if dy != 0 {
		emit(evRel, relY, int32(dy))
	}
	syn()
}

func mouseButton(b int, down bool, mods int) {
	var code uint16
	switch b {
	case 1:
		code = btnRight
	case 2:
		code = btnMiddle
	default:
		code = btnLeft
	}
	withMods(mods, func() {
		if down {
			keyDown(code)
		} else {
			keyUp(code)
		}
		syn()
	})
	// Track held state so releaseAllModifiers can clean up a dangling drag.
	switch code {
	case btnLeft:
		leftDown = down
	case btnRight:
		rightDown = down
	}
}

// scrollWheel scrolls vertically (REL_WHEEL) and/or horizontally (REL_HWHEEL).
// The dx/dy arrive already signed for the scroll-direction preference.
func scrollWheel(dx, dy int) {
	if dy != 0 {
		emit(evRel, relWheel, int32(dy))
	}
	if dx != 0 {
		emit(evRel, relHWheel, int32(dx))
	}
	if dx != 0 || dy != 0 {
		syn()
	}
}

// zoom — Ctrl+'=' to zoom in, Ctrl+'-' to zoom out (the cross-app Linux
// convention; Ctrl+scroll behaves inconsistently across toolkits, so we use
// the keyboard shortcut here).
func zoom(d int) {
	if d == 0 {
		return
	}
	var key uint16 = keyEqual // '='  → zoom in
	if d < 0 {
		key = keyMinus // '-' → zoom out
	}
	withMods(modCtrl, func() { tap(key) })
}

// ---- consumer / media keys ----

var mediaKey = map[string]uint16{
	"playpause":  keyPlayPause,
	"next":       keyNextSong,
	"prev":       keyPreviousSong,
	"mute":       keyMute,
	"volup":      keyVolumeUp,
	"voldown":    keyVolumeDown,
	"brightup":   keyBrightnessUp,
	"brightdown": keyBrightnessDown,
	// rewind/ffwd: no clean standalone evdev key on Linux — no-op for now.
}

func consumer(u string) {
	if code, ok := mediaKey[u]; ok {
		tap(code)
	}
}

// releaseAllModifiers lifts any stuck modifiers/buttons on disconnect so a
// dropped connection can't leave Ctrl/Super or a mouse button latched down.
func releaseAllModifiers() {
	for _, b := range []int{modCtrl, modShift, modAlt, modGUI} {
		if heldMask&b != 0 {
			keyUp(modKey(b))
		}
	}
	heldMask = 0
	if leftDown {
		keyUp(btnLeft)
		leftDown = false
	}
	if rightDown {
		keyUp(btnRight)
		rightDown = false
	}
	syn()
}

// allUsedKeys returns every EV_KEY code we register with UI_SET_KEYBIT. It must
// cover the ASCII map, the named-key map, the modifiers, and the media keys.
func allUsedKeys() []uint {
	set := map[uint16]struct{}{}
	add := func(c uint16) { set[c] = struct{}{} }

	// All letter/digit/symbol key codes plus Shift (asciiKey can set shift).
	for _, c := range letterKey {
		add(c)
	}
	for _, r := range "0123456789" {
		c, _, _ := digitKey(r)
		add(c)
	}
	for _, e := range symbolKey {
		add(e.code)
	}
	add(keySpace)

	// Named keys.
	for _, c := range namedKey {
		add(c)
	}
	// Modifiers.
	add(keyLeftCtrl)
	add(keyLeftShift)
	add(keyLeftAlt)
	add(keyLeftMeta)
	// Media keys.
	for _, c := range mediaKey {
		add(c)
	}

	out := make([]uint, 0, len(set))
	for c := range set {
		out = append(out, uint(c))
	}
	return out
}

func firstRune(s string) rune {
	for _, r := range s {
		return r
	}
	return 0
}
