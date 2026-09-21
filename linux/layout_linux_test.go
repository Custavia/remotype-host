//go:build linux

package main

import (
	"os/exec"
	"testing"
	"time"
)

// Types characters under the Spanish layout and reads back what actually went
// out through uinput. The expected keycodes are the kernel's own numbers and
// come from xkbcommon's answer for that layout, not from our table — so this
// proves the translation, the AltGr press, and the release order, on the real
// device. Skips where /dev/uinput or xkbcli is absent.
func TestSpanishLayoutTyping(t *testing.T) {
	if _, err := exec.LookPath("xkbcli"); err != nil {
		t.Skip("xkbcli (libxkbcommon-tools) not installed")
	}
	fd, cleanup := setup(t)
	defer cleanup()

	layoutInit("es")
	if layoutIsUS() {
		t.Fatal("layout es was not adopted")
	}

	const (
		key2         = 3
		keyMinus     = 12
		keyN         = 49
		keySemicolon = 39
		keyComma     = 51
	)
	cases := []struct {
		ch   string
		want []uint16 // key-down codes in order: modifiers first, then the key
	}{
		{"ñ", []uint16{keySemicolon}},           // the US ; position, no modifier
		{"'", []uint16{keyMinus}},               // the US - position
		{";", []uint16{keyLeftShift, keyComma}}, // Shift + the comma key
		{"@", []uint16{keyRightAlt, key2}},      // AltGr + 2
		{"n", []uint16{keyN}},                   // letters survive
	}
	for _, c := range cases {
		typeChar(c.ch, 0)
		time.Sleep(20 * time.Millisecond)
		evs := drain(fd)
		var downs []uint16
		ups := 0
		for _, ev := range evs {
			switch ev.Value {
			case 1:
				downs = append(downs, ev.Code)
			case 0:
				ups++
			}
		}
		if len(downs) != len(c.want) || ups != len(c.want) {
			t.Errorf("%q: downs=%v ups=%d, want downs=%v ups=%d", c.ch, downs, ups, c.want, len(c.want))
			continue
		}
		for i := range c.want {
			if downs[i] != c.want[i] {
				t.Errorf("%q: key-down %d was %d, want %d (all: %v)", c.ch, i, downs[i], c.want[i], downs)
			}
		}
	}

}

// Accented letters with no key of their own go out as the layout's dead key
// followed by the base letter — the sequence a physical keyboard user types,
// which is what the desktop knows how to compose.
func TestSpanishDeadKeys(t *testing.T) {
	if _, err := exec.LookPath("xkbcli"); err != nil {
		t.Skip("xkbcli (libxkbcommon-tools) not installed")
	}
	fd, cleanup := setup(t)
	defer cleanup()
	layoutInit("es")

	const (
		keyE          = 18
		keyU          = 22
		keyApostrophe = 40 // AC11 on Spanish: dead_acute, Shift for dead_diaeresis
	)
	cases := []struct {
		ch   string
		want []uint16 // key-down codes in order
	}{
		{"é", []uint16{keyApostrophe, keyE}},
		{"É", []uint16{keyApostrophe, keyLeftShift, keyE}},
		{"ü", []uint16{keyLeftShift, keyApostrophe, keyU}},
	}
	for _, c := range cases {
		typeChar(c.ch, 0)
		time.Sleep(30 * time.Millisecond)
		var downs []uint16
		for _, ev := range drain(fd) {
			if ev.Value == 1 {
				downs = append(downs, ev.Code)
			}
		}
		if len(downs) != len(c.want) {
			t.Errorf("%q: downs=%v want %v", c.ch, downs, c.want)
			continue
		}
		for i := range c.want {
			if downs[i] != c.want[i] {
				t.Errorf("%q: key-down %d was %d, want %d (all: %v)", c.ch, i, downs[i], c.want[i], downs)
			}
		}
	}

	// A character with no key and no dead-key route is skipped, and nothing
	// stays held. (ẞ is NOT such a character on Spanish — it is AltGr+Shift+S —
	// which is the kind of assumption this layer exists to stop making.)
	typeChar("字", 0)
	time.Sleep(30 * time.Millisecond)
	if evs := drain(fd); len(evs) != 0 {
		t.Errorf("字 on es should type nothing, got %d events", len(evs))
	}
}
