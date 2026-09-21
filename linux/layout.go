package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/text/unicode/norm"
)

// Keyboard-layout-aware typing.
//
// uinput is a scancode protocol: the host says "the key at position AC10 went
// down" and the desktop's active layout decides what character that is. The
// built-in table in inject_linux.go is the US layout, so on any other layout
// the same scancodes type the wrong thing — measured, not guessed: under the
// Spanish layout the US ";" key types "ñ", and the US "'" key is a dead accent
// that types nothing and corrupts the next letter.
//
// The fix is to translate each character under the layout that is actually
// active, using xkbcommon — the one layer X11 and every Wayland compositor
// share for exactly this decision. `xkbcli how-to-type` answers "which key,
// which level, which modifiers produce this character in this layout", and
// the answer is cached per character, so a running host asks once per distinct
// character it ever types.
//
// Characters a layout reaches only through a dead-key sequence (é on Spanish
// is ´ then e) are decomposed: the accent becomes the layout's dead key, the
// base letter its own key, and the two are typed in order so the desktop
// composes them exactly as it would for a physical keyboard. What has no
// direct key and no dead-key route is reported once and skipped, which is the
// honest failure: a wrong letter would be worse than a missing one.

// modAltGr is the level-3 chooser (ISO_Level3_Shift, xkb "Mod5"), which the
// phone never sends but non-US layouts need for characters such as @ and #.
const modAltGr = 16

type keyPress struct {
	code uint16 // evdev keycode
	mods int    // modShift and/or modAltGr
}

var (
	layoutMu      sync.Mutex
	layoutName    string // xkb layout, e.g. "es"; "" or "us" means the built-in table
	layoutVariant string
	layoutSource  string // how it was chosen, for the log
	xkbcliPath    string
	layoutCache   = map[rune][]keyPress{}
	layoutMissed  = map[rune]bool{}
)

// deadKeyFor maps a Unicode combining mark (what NFD peels off an accented
// letter) to the xkb dead keysym a layout puts on a key for it.
var deadKeyFor = map[rune]string{
	0x0300: "dead_grave",
	0x0301: "dead_acute",
	0x0302: "dead_circumflex",
	0x0303: "dead_tilde",
	0x0304: "dead_macron",
	0x0306: "dead_breve",
	0x0307: "dead_abovedot",
	0x0308: "dead_diaeresis",
	0x030A: "dead_abovering",
	0x030B: "dead_doubleacute",
	0x030C: "dead_caron",
	0x0327: "dead_cedilla",
	0x0328: "dead_ogonek",
}

// deadKeyRoute splits an accented letter into its base letter and the dead
// keysym that produces the accent, or reports that there is no such route.
func deadKeyRoute(r rune) (base rune, dead string, ok bool) {
	parts := []rune(norm.NFD.String(string(r)))
	if len(parts) != 2 {
		return 0, "", false
	}
	dead, ok = deadKeyFor[parts[1]]
	if !ok {
		return 0, "", false
	}
	return parts[0], dead, true
}

// layoutInit chooses the layout: the -layout flag, then REMOTYPE_LAYOUT, then
// whatever the desktop reports, then US. Accepts "es", "es(cat)" and "es:cat".
func layoutInit(flagValue string) {
	name, variant, source := "", "", ""
	switch {
	case flagValue != "":
		name, variant = splitLayout(flagValue)
		source = "-layout"
	case os.Getenv("REMOTYPE_LAYOUT") != "":
		name, variant = splitLayout(os.Getenv("REMOTYPE_LAYOUT"))
		source = "REMOTYPE_LAYOUT"
	default:
		name, variant, source = detectLayout()
	}
	if name == "" {
		name, source = "us", source+" (nothing reported; assuming US)"
	}
	layoutMu.Lock()
	layoutName, layoutVariant, layoutSource = name, variant, source
	xkbcliPath, _ = exec.LookPath("xkbcli")
	layoutMu.Unlock()

	shown := name
	if variant != "" {
		shown += "(" + variant + ")"
	}
	if layoutIsUS() {
		logf("keyboard layout: %s via %s — built-in table", shown, source)
		return
	}
	if xkbcliPath == "" {
		logf("keyboard layout: %s via %s — but xkbcli is not installed (package libxkbcommon-tools), so typing falls back to the US table and non-US characters will be wrong", shown, source)
		return
	}
	logf("keyboard layout: %s via %s — characters translated through xkbcommon", shown, source)
}

func splitLayout(s string) (name, variant string) {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "(:"); i >= 0 {
		name = s[:i]
		variant = strings.Trim(s[i+1:], "()")
		return name, variant
	}
	return s, ""
}

// layoutDisplayName is the human label for the active layout, e.g. "es" or
// "es(cat)".
func layoutDisplayName() string {
	layoutMu.Lock()
	defer layoutMu.Unlock()
	if layoutVariant != "" {
		return layoutName + "(" + layoutVariant + ")"
	}
	if layoutName == "" {
		return "us"
	}
	return layoutName
}

// layoutIsUS reports whether the built-in US table applies. That is also the
// path taken when xkbcli is missing, so the host keeps typing something rather
// than nothing.
func layoutIsUS() bool {
	layoutMu.Lock()
	defer layoutMu.Unlock()
	return layoutName == "" || (layoutName == "us" && layoutVariant == "") || xkbcliPath == ""
}

// detectLayout asks the desktop. Each source is tried in turn and the first
// answer wins; the caller falls back to US when none of them speak.
func detectLayout() (name, variant, source string) {
	// X11: setxkbmap knows the server's layout list. The first entry is the
	// default group; a user who toggled to a later group is not visible from
	// outside the display, and -layout exists for that.
	if os.Getenv("DISPLAY") != "" {
		if out, err := exec.Command("setxkbmap", "-query").Output(); err == nil {
			var layouts, variants string
			for _, line := range strings.Split(string(out), "\n") {
				if k, v, ok := strings.Cut(line, ":"); ok {
					switch strings.TrimSpace(k) {
					case "layout":
						layouts = strings.TrimSpace(v)
					case "variant":
						variants = strings.TrimSpace(v)
					}
				}
			}
			if layouts != "" {
				name = strings.Split(layouts, ",")[0]
				variant = strings.Split(variants+",", ",")[0]
				return name, variant, "setxkbmap"
			}
		}
	}
	// GNOME (X11 or Wayland): mru-sources is the most recently USED source,
	// i.e. the active one; sources is the configured list.
	for _, key := range []string{"mru-sources", "sources"} {
		out, err := exec.Command("gsettings", "get", "org.gnome.desktop.input-sources", key).Output()
		if err != nil {
			continue
		}
		// [('xkb', 'es+cat'), ('xkb', 'us')]
		re := regexp.MustCompile(`\('xkb',\s*'([^']+)'\)`)
		if m := re.FindStringSubmatch(string(out)); m != nil {
			name, variant = m[1], ""
			if i := strings.Index(name, "+"); i >= 0 {
				name, variant = name[:i], name[i+1:]
			}
			return name, variant, "gsettings " + key
		}
	}
	// KDE Plasma: kxkbrc lists the configured layouts.
	if home, err := os.UserHomeDir(); err == nil {
		if f, err := os.Open(filepath.Join(home, ".config", "kxkbrc")); err == nil {
			defer f.Close()
			var layouts, variants string
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				if k, v, ok := strings.Cut(sc.Text(), "="); ok {
					switch strings.TrimSpace(k) {
					case "LayoutList":
						layouts = strings.TrimSpace(v)
					case "VariantList":
						variants = strings.TrimSpace(v)
					}
				}
			}
			if layouts != "" {
				name = strings.Split(layouts, ",")[0]
				variant = strings.Split(variants+",", ",")[0]
				return name, variant, "kxkbrc"
			}
		}
	}
	return "", "", "no desktop layout source found"
}

// One row of `xkbcli how-to-type`: KEYCODE, KEY NAME, LAYOUT#, LAYOUT NAME
// (which can contain spaces), LEVEL#, then the modifier list in brackets.
var howToTypeRow = regexp.MustCompile(`(?m)^\s*(\d+)\s+\S+\s+\d+\s+.*?\s+(\d+)\s+\[([^\]]*)\]`)

// xkbQuery asks xkbcli how one keysym is typed under the active layout. The
// argument is a Unicode code point ("0x00F1") or, with keysymName, a keysym
// name such as dead_acute.
func xkbQuery(arg string, keysymName bool) (keyPress, bool) {
	layoutMu.Lock()
	name, variant, bin := layoutName, layoutVariant, xkbcliPath
	layoutMu.Unlock()
	if bin == "" {
		return keyPress{}, false
	}
	args := []string{"how-to-type"}
	if keysymName {
		args = append(args, "--keysym")
	}
	args = append(args, "--layout", name)
	if variant != "" {
		args = append(args, "--variant", variant)
	}
	args = append(args, arg)
	out, err := exec.Command(bin, args...).Output()
	if err != nil {
		return keyPress{}, false
	}
	return parseHowToType(string(out))
}

// layoutSequence resolves one character under the active layout to the key
// presses that type it: one for a character with its own key, two for one
// reached through a dead key. The result is cached either way, so a character
// the layout cannot type costs one lookup and one log line, not one of each
// per keystroke.
func layoutSequence(r rune) ([]keyPress, bool) {
	layoutMu.Lock()
	if seq, ok := layoutCache[r]; ok {
		layoutMu.Unlock()
		return seq, true
	}
	if layoutMissed[r] {
		layoutMu.Unlock()
		return nil, false
	}
	name := layoutName
	layoutMu.Unlock()

	var seq []keyPress
	if kp, ok := xkbQuery(fmt.Sprintf("0x%04X", r), false); ok {
		seq = []keyPress{kp}
	} else if base, dead, ok := deadKeyRoute(r); ok {
		deadKP, okDead := xkbQuery(dead, true)
		baseKP, okBase := xkbQuery(fmt.Sprintf("0x%04X", base), false)
		if okDead && okBase {
			seq = []keyPress{deadKP, baseKP}
		}
	}

	layoutMu.Lock()
	if seq != nil {
		layoutCache[r] = seq
	} else {
		layoutMissed[r] = true
	}
	layoutMu.Unlock()
	if seq == nil {
		logf("layout %s cannot type %q (U+%04X) — no key and no dead-key route; skipped", name, r, r)
	}
	return seq, seq != nil
}

// parseHowToType picks the cheapest row: the fewest modifiers, and only
// modifiers this host can press (Shift, AltGr). A row that needs Lock or a
// modifier we do not model is skipped rather than approximated.
func parseHowToType(out string) (keyPress, bool) {
	best, found := keyPress{}, false
	bestCount := 99
	for _, m := range howToTypeRow.FindAllStringSubmatch(out, -1) {
		xkbCode, err := strconv.Atoi(m[1])
		if err != nil || xkbCode < 9 || xkbCode-8 > 0xFFFF {
			continue
		}
		mods, count, ok := 0, 0, true
		for _, tok := range strings.Fields(m[3]) {
			switch tok {
			case "Shift":
				mods |= modShift
			case "Mod5":
				mods |= modAltGr
			default:
				ok = false
			}
			count++
		}
		if !ok {
			continue
		}
		if !found || count < bestCount {
			// xkb keycodes are evdev keycodes offset by 8.
			best, bestCount, found = keyPress{code: uint16(xkbCode - 8), mods: mods}, count, true
		}
	}
	return best, found
}
