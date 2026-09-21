package main

import "testing"

// Real `xkbcli how-to-type` output, captured on Ubuntu 24.04 (xkbcommon 1.6).
const howToTypeNtilde = `keysym: ntilde (0xf1)
KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS
47       AC10      1        Spanish              1       [ ]
47       AC10      1        Spanish              1       [ Lock ]
`

const howToTypeAtSpanish = `keysym: at (0x40)
KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS
11       AE02      1        Spanish              3       [ Mod5 ]
24       AD01      1        Spanish              3       [ Mod5 ]
`

const howToTypeSemicolonSpanish = `keysym: semicolon (0x3b)
KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS
59       AB08      1        Spanish              2       [ Shift ]
`

const howToTypeAtUS = `keysym: at (0x40)
KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS
11       AE02      1        English (US)         2       [ Shift ]
`

// é on the Spanish layout is a dead-key sequence: xkbcli prints the header and
// no rows.
const howToTypeEacuteSpanish = `keysym: eacute (0xe9)
KEYCODE  KEY NAME  LAYOUT   LAYOUT NAME          LEVEL#  MODIFIERS
`

func TestParseHowToType(t *testing.T) {
	cases := []struct {
		name string
		out  string
		want keyPress
		ok   bool
	}{
		{"ñ on Spanish is the US ; key, no modifiers", howToTypeNtilde, keyPress{code: 39, mods: 0}, true},
		{"@ on Spanish needs AltGr on the 2 key", howToTypeAtSpanish, keyPress{code: 3, mods: modAltGr}, true},
		{"; on Spanish is Shift on the comma key", howToTypeSemicolonSpanish, keyPress{code: 51, mods: modShift}, true},
		{"@ on US is Shift+2", howToTypeAtUS, keyPress{code: 3, mods: modShift}, true},
		{"é on Spanish has no direct key", howToTypeEacuteSpanish, keyPress{}, false},
		{"garbage is not a key", "not xkbcli output", keyPress{}, false},
	}
	for _, c := range cases {
		got, ok := parseHowToType(c.out)
		if ok != c.ok || got != c.want {
			t.Errorf("%s: got %+v ok=%v, want %+v ok=%v", c.name, got, ok, c.want, c.ok)
		}
	}
}

func TestSplitLayout(t *testing.T) {
	for in, want := range map[string][2]string{
		"es":      {"es", ""},
		"es(cat)": {"es", "cat"},
		"es:cat":  {"es", "cat"},
		" de ":    {"de", ""},
	} {
		n, v := splitLayout(in)
		if n != want[0] || v != want[1] {
			t.Errorf("splitLayout(%q) = %q,%q want %q,%q", in, n, v, want[0], want[1])
		}
	}
}

func TestDeadKeyRoute(t *testing.T) {
	cases := map[rune]struct {
		base rune
		dead string
		ok   bool
	}{
		'é': {'e', "dead_acute", true},
		'É': {'E', "dead_acute", true},
		'ü': {'u', "dead_diaeresis", true},
		'ç': {'c', "dead_cedilla", true},
		'ñ': {'n', "dead_tilde", true},
		'e': {0, "", false}, // nothing to decompose
		'€': {0, "", false}, // no combining mark
	}
	for r, want := range cases {
		base, dead, ok := deadKeyRoute(r)
		if ok != want.ok || base != want.base || dead != want.dead {
			t.Errorf("deadKeyRoute(%q) = %q,%q,%v want %q,%q,%v", r, base, dead, ok, want.base, want.dead, want.ok)
		}
	}
}
