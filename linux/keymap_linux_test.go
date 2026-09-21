//go:build linux

// Loopback validation of the uinput keymap.
//
// inject_linux.go carries an honesty note: its ASCII→KEY_* and named-key tables
// were transcribed by hand from the US kernel keymap and had never been run on
// Linux. Hand-transcribed tables fail in exactly one way — a character points at
// the wrong keycode, or carries the wrong shift state — and no amount of reading
// the source catches it, because the reader makes the same assumption the author
// made.
//
// So this test does not read the table. It creates the real uinput device,
// injects real events, reads them back off the resulting /dev/input/eventN, and
// decodes each keycode through an INDEPENDENT reference keymap built from the
// kernel's own canonical numbering (linux/input-event-codes.h). If the two
// disagree about what character a key produces, the test fails and names both.
//
// Requires /dev/uinput and CAP_SYS_ADMIN-ish access. It is skipped when the
// device is absent, so `go test ./...` stays green on a dev machine. To run it:
//
//	GOOS=linux GOARCH=arm64 go test -c -o /tmp/keymap.test .
//	docker run --rm --privileged -v /tmp/keymap.test:/t:ro alpine /t -test.v
package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// ---------------------------------------------------------------------------
// The independent reference: kernel keycode -> (unshifted, shifted) on US QWERTY.
//
// These numbers are the kernel's own, from <linux/input-event-codes.h>. They are
// written here as literals on purpose: importing them from inject_linux.go would
// make the test circular, validating the table against itself.
// ---------------------------------------------------------------------------

type usKey struct {
	plain   rune
	shifted rune
	name    string // for named (non-character) keys
}

var refKeymap = map[uint16]usKey{
	1:  {name: "esc"},
	2:  {plain: '1', shifted: '!'},
	3:  {plain: '2', shifted: '@'},
	4:  {plain: '3', shifted: '#'},
	5:  {plain: '4', shifted: '$'},
	6:  {plain: '5', shifted: '%'},
	7:  {plain: '6', shifted: '^'},
	8:  {plain: '7', shifted: '&'},
	9:  {plain: '8', shifted: '*'},
	10: {plain: '9', shifted: '('},
	11: {plain: '0', shifted: ')'},
	12: {plain: '-', shifted: '_'},
	13: {plain: '=', shifted: '+'},
	14: {name: "backspace"},
	15: {name: "tab"},
	16: {plain: 'q', shifted: 'Q'},
	17: {plain: 'w', shifted: 'W'},
	18: {plain: 'e', shifted: 'E'},
	19: {plain: 'r', shifted: 'R'},
	20: {plain: 't', shifted: 'T'},
	21: {plain: 'y', shifted: 'Y'},
	22: {plain: 'u', shifted: 'U'},
	23: {plain: 'i', shifted: 'I'},
	24: {plain: 'o', shifted: 'O'},
	25: {plain: 'p', shifted: 'P'},
	26: {plain: '[', shifted: '{'},
	27: {plain: ']', shifted: '}'},
	28: {name: "enter"},
	29: {name: "leftctrl"},
	30: {plain: 'a', shifted: 'A'},
	31: {plain: 's', shifted: 'S'},
	32: {plain: 'd', shifted: 'D'},
	33: {plain: 'f', shifted: 'F'},
	34: {plain: 'g', shifted: 'G'},
	35: {plain: 'h', shifted: 'H'},
	36: {plain: 'j', shifted: 'J'},
	37: {plain: 'k', shifted: 'K'},
	38: {plain: 'l', shifted: 'L'},
	39: {plain: ';', shifted: ':'},
	40: {plain: '\'', shifted: '"'},
	41: {plain: '`', shifted: '~'},
	42: {name: "leftshift"},
	43: {plain: '\\', shifted: '|'},
	44: {plain: 'z', shifted: 'Z'},
	45: {plain: 'x', shifted: 'X'},
	46: {plain: 'c', shifted: 'C'},
	47: {plain: 'v', shifted: 'V'},
	48: {plain: 'b', shifted: 'B'},
	49: {plain: 'n', shifted: 'N'},
	50: {plain: 'm', shifted: 'M'},
	51: {plain: ',', shifted: '<'},
	52: {plain: '.', shifted: '>'},
	53: {plain: '/', shifted: '?'},
	54: {name: "rightshift"},
	56: {name: "leftalt"},
	57: {plain: ' ', shifted: ' '},
	58: {name: "capslock"},
	59: {name: "f1"}, 60: {name: "f2"}, 61: {name: "f3"}, 62: {name: "f4"},
	63: {name: "f5"}, 64: {name: "f6"}, 65: {name: "f7"}, 66: {name: "f8"},
	67: {name: "f9"}, 68: {name: "f10"}, 87: {name: "f11"}, 88: {name: "f12"},
	97:  {name: "rightctrl"},
	100: {name: "rightalt"},
	102: {name: "home"},
	103: {name: "up"},
	104: {name: "pageup"},
	105: {name: "left"},
	106: {name: "right"},
	107: {name: "end"},
	108: {name: "down"},
	109: {name: "pagedown"},
	110: {name: "insert"},
	111: {name: "delete"},
	125: {name: "leftmeta"},
	126: {name: "rightmeta"},

	// Keypad. Note the kernel's numbering is not in digit order — it follows the
	// physical block, 7-8-9 first — which is exactly the sort of detail a
	// hand-transcribed table gets wrong, so it is worth asserting.
	55: {name: "kpasterisk"},
	71: {name: "kp7"}, 72: {name: "kp8"}, 73: {name: "kp9"}, 74: {name: "kpminus"},
	75: {name: "kp4"}, 76: {name: "kp5"}, 77: {name: "kp6"}, 78: {name: "kpplus"},
	79: {name: "kp1"}, 80: {name: "kp2"}, 81: {name: "kp3"},
	82: {name: "kp0"}, 83: {name: "kpdot"},
	96: {name: "kpenter"}, 98: {name: "kpslash"},
}

// aliases maps the host's own key names to the kernel name where the two differ
// by spelling rather than by meaning. Anything not listed must match the kernel
// name directly (allowing the left*/right* prefix).
var aliases = map[string]string{
	"escape":  "esc",
	"return":  "enter",
	"fdel":    "delete",
	"del":     "delete",
	"kpdiv":   "kpslash",
	"kpmul":   "kpasterisk",
	"space":   "space", // a character key; handled explicitly below
	"pgup":    "pageup",
	"pgdn":    "pagedown",
	"pagedn":  "pagedown",
	"ins":     "insert",
	"bksp":    "backspace",
	"back":    "backspace",
	"cmd":     "leftmeta",
	"meta":    "leftmeta",
	"super":   "leftmeta",
	"win":     "leftmeta",
	"ctrl":    "leftctrl",
	"control": "leftctrl",
	"alt":     "leftalt",
	"option":  "leftalt",
	"shift":   "leftshift",
}

const (
	refLeftShift  = 42
	refRightShift = 54
	evSizeof      = int(unsafe.Sizeof(inputEvent{}))
)

// ---------------------------------------------------------------------------
// evdev reader
// ---------------------------------------------------------------------------

// openOurDevice opens the evdev node belonging to the device injectInit just
// created.
//
// It asks uinput directly (UI_GET_SYSNAME) rather than diffing /dev/input,
// which matters twice over: on a desktop with real keyboards the diff could
// pick the wrong node, and inside a container there is no udev at all, so the
// node never appears on its own. We resolve the device through sysfs and mknod
// it ourselves when it is missing.
func openOurDevice(t *testing.T) int {
	t.Helper()
	const uiGetSysname = 0x8040552c // _IOC(READ, 'U', 44, 64)

	var nameBuf [64]byte
	if err := ioctl(uinputFD, uiGetSysname, uintptr(unsafe.Pointer(&nameBuf))); err != nil {
		t.Fatalf("UI_GET_SYSNAME: %v", err)
	}
	sysname := strings.TrimRight(string(nameBuf[:]), "\x00")
	if sysname == "" {
		t.Fatal("uinput returned an empty sysfs name")
	}

	// /sys/class/input/inputN/eventM/dev holds "major:minor".
	base := "/sys/class/input/" + sysname
	kids, err := os.ReadDir(base)
	if err != nil {
		t.Fatalf("read %s: %v", base, err)
	}
	event := ""
	for _, k := range kids {
		if strings.HasPrefix(k.Name(), "event") {
			event = k.Name()
			break
		}
	}
	if event == "" {
		t.Fatalf("no eventN child under %s", base)
	}

	devFile := base + "/" + event + "/dev"
	raw, err := os.ReadFile(devFile)
	if err != nil {
		t.Fatalf("read %s: %v", devFile, err)
	}
	var major, minor uint32
	if _, err := fmt.Sscanf(strings.TrimSpace(string(raw)), "%d:%d", &major, &minor); err != nil {
		t.Fatalf("parse %q from %s: %v", raw, devFile, err)
	}

	path := "/dev/input/" + event
	if _, err := os.Stat(path); os.IsNotExist(err) {
		_ = os.MkdirAll("/dev/input", 0o755)
		if err := unix.Mknod(path, unix.S_IFCHR|0o600, int(unix.Mkdev(major, minor))); err != nil {
			t.Fatalf("mknod %s (%d:%d): %v — no udev here, and we cannot create the node",
				path, major, minor, err)
		}
		t.Logf("no udev in this environment; created %s (%d:%d) by hand", path, major, minor)
	}

	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NONBLOCK, 0)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	t.Logf("reading back from %s (uinput sysfs name %s)", path, sysname)
	return fd
}

// drain reads every pending event, returning the EV_KEY ones in order.
func drain(fd int) []inputEvent {
	var out []inputEvent
	buf := make([]byte, evSizeof*64)
	deadline := time.Now().Add(250 * time.Millisecond)
	for time.Now().Before(deadline) {
		n, err := unix.Read(fd, buf)
		if err != nil {
			if err == unix.EAGAIN {
				time.Sleep(2 * time.Millisecond)
				continue
			}
			break
		}
		for off := 0; off+evSizeof <= n; off += evSizeof {
			ev := *(*inputEvent)(unsafe.Pointer(&buf[off]))
			if ev.Type == evKey {
				out = append(out, ev)
			}
		}
		if n > 0 {
			// Give the kernel a beat in case the packet is split.
			time.Sleep(5 * time.Millisecond)
			deadline = time.Now().Add(60 * time.Millisecond)
		}
	}
	return out
}

// decode turns a captured key sequence into (keycode, shiftHeld). It tracks
// shift as a held modifier exactly as a real consumer (libinput) would.
func decode(evs []inputEvent) (code uint16, shift bool, err error) {
	var shiftDepth int
	found := false
	for _, ev := range evs {
		isShift := ev.Code == refLeftShift || ev.Code == refRightShift
		switch {
		case isShift && ev.Value == 1:
			shiftDepth++
		case isShift && ev.Value == 0:
			shiftDepth--
		case !isShift && ev.Value == 1:
			if found {
				return 0, false, fmt.Errorf("more than one non-modifier key pressed")
			}
			code, shift, found = ev.Code, shiftDepth > 0, true
		}
	}
	if !found {
		return 0, false, fmt.Errorf("no key press seen (%d events)", len(evs))
	}
	return code, shift, nil
}

func setup(t *testing.T) (readFD int, cleanup func()) {
	t.Helper()
	if _, err := os.Stat("/dev/uinput"); err != nil {
		t.Skip("no /dev/uinput — run this inside a privileged Linux container")
	}
	if err := injectInit(); err != nil {
		t.Skipf("cannot create uinput device (need privileges): %v", err)
	}
	time.Sleep(150 * time.Millisecond) // let udev publish the node
	fd := openOurDevice(t)
	drain(fd) // discard the device-creation noise
	return fd, func() {
		unix.Close(fd)
		injectClose()
	}
}

// ---------------------------------------------------------------------------
// The tests
// ---------------------------------------------------------------------------

// TestPrintableASCII is the one that matters: every printable character, typed
// for real, read back, and decoded through the independent reference.
func TestPrintableASCII(t *testing.T) {
	fd, cleanup := setup(t)
	defer cleanup()

	var missing, wrong []string
	checked := 0

	for r := rune(0x20); r <= 0x7e; r++ {
		if _, _, ok := asciiKey(r); !ok {
			missing = append(missing, fmt.Sprintf("%q", r))
			continue
		}
		drain(fd)
		typeChar(string(r), 0)
		code, shift, err := decode(drain(fd))
		if err != nil {
			wrong = append(wrong, fmt.Sprintf("%q: %v", r, err))
			continue
		}
		ref, known := refKeymap[code]
		if !known {
			wrong = append(wrong, fmt.Sprintf("%q emitted keycode %d, which is not a US-layout key", r, code))
			continue
		}
		got := ref.plain
		if shift {
			got = ref.shifted
		}
		if got != r {
			wrong = append(wrong, fmt.Sprintf(
				"%q -> keycode %d shift=%v, which the kernel keymap says is %q", r, code, shift, got))
			continue
		}
		checked++
	}

	t.Logf("verified %d printable characters against the kernel keymap", checked)
	if len(missing) > 0 {
		t.Errorf("%d printable ASCII characters have no mapping: %s",
			len(missing), strings.Join(missing, " "))
	}
	for _, w := range wrong {
		t.Errorf("wrong mapping: %s", w)
	}
}

// TestNamedKeys checks the non-character keys resolve to the kernel's codes.
func TestNamedKeys(t *testing.T) {
	fd, cleanup := setup(t)
	defer cleanup()

	names := make([]string, 0, len(namedKey))
	for n := range namedKey {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, name := range names {
		drain(fd)
		pressNamed(name, 0)
		code, _, err := decode(drain(fd))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		ref, known := refKeymap[code]
		if !known {
			t.Errorf("%s emitted keycode %d, absent from the kernel reference", name, code)
			continue
		}

		want := strings.ToLower(strings.NewReplacer(" ", "", "_", "", "-", "").Replace(name))
		if a, ok := aliases[want]; ok {
			want = a
		}

		// A few named keys are also character keys (space is the obvious one),
		// so they carry a rune rather than a kernel name. Check the rune.
		if ref.name == "" {
			if want == "space" && ref.plain == ' ' {
				continue
			}
			t.Errorf("%s emitted keycode %d, which is the character key %q, not a named key",
				name, code, ref.plain)
			continue
		}

		got := ref.name
		// Accept the left*/right* prefix for modifiers named bare.
		if got != want && got != "left"+want && got != "right"+want {
			t.Errorf("%q emitted keycode %d = %q, not %q", name, code, got, want)
		}
	}
}

// TestModifiersReleased guards the bug class where a latched modifier is never
// lifted, leaving the desktop stuck in Ctrl or Shift after a chord.
func TestModifiersReleased(t *testing.T) {
	fd, cleanup := setup(t)
	defer cleanup()

	drain(fd)
	typeChar("A", 0) // shift is inferred from the character
	evs := drain(fd)

	held := map[uint16]int{}
	for _, ev := range evs {
		if _, isKey := refKeymap[ev.Code]; !isKey {
			continue
		}
		switch ev.Value {
		case 1:
			held[ev.Code]++
		case 0:
			held[ev.Code]--
		}
	}
	for code, n := range held {
		if n != 0 {
			t.Errorf("keycode %d (%s) left with press/release imbalance %d — a stuck key",
				code, refKeymap[code].name, n)
		}
	}
}
