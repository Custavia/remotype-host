//go:build windows

// Cast subsystem, Windows side (docs/CASTING.md §9.3, slice 1): the Miracast
// capability gate (netsh), the process-global native cast session (Win+K
// trigger + guided fallback + display-topology watcher + power assertion),
// and the platform half of discovery (the synthetic Miracast target).
// Family B (Chromecast streaming) is a later phase — cast.start for
// cast/airplay targets answers `unsupported`. Stubs in cast_stub.go.
//
// NOTE: queryMiracastSupport shells out to netsh — the first (deliberate)
// os/exec use in this host. Everything else stays explicit-syscall.
package main

import (
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// user32 is declared in inject_windows.go (same package + build tag);
// SetThreadExecutionState is bound in extras_windows.go's kernel32 block.
var (
	procGetDisplayConfigBufferSizes = user32.NewProc("GetDisplayConfigBufferSizes")
	procQueryDisplayConfig          = user32.NewProc("QueryDisplayConfig")
)

// --- Miracast capability (netsh) ---------------------------------------------

const miracastRecheck = 60 * time.Second

var (
	miraMu       sync.Mutex
	miraCapable  bool
	miraChecked  bool
	miraTickStop chan struct{}
)

// castInit runs the startup capability probe (async — netsh takes a beat and
// main() must not block on it).
func castInit() {
	go refreshMiracastCapability()
}

// miracastAvailable is the cached verdict, read per snapshot by the scanner.
func miracastAvailable() bool {
	miraMu.Lock()
	defer miraMu.Unlock()
	return miraCapable
}

// castScanHook re-checks capability every 60 s while any phone holds a scan
// subscription (drivers/adapters can change: USB Wi-Fi, radio toggled).
func castScanHook(active bool) {
	miraMu.Lock()
	defer miraMu.Unlock()
	if active {
		if miraTickStop != nil {
			return
		}
		stop := make(chan struct{})
		miraTickStop = stop
		go func() {
			t := time.NewTicker(miracastRecheck)
			defer t.Stop()
			for {
				select {
				case <-stop:
					return
				case <-t.C:
					refreshMiracastCapability()
				}
			}
		}()
		return
	}
	if miraTickStop != nil {
		close(miraTickStop)
		miraTickStop = nil
	}
}

// refreshMiracastCapability updates the cached verdict; on change the scanner
// re-emits its snapshot so the synthetic Miracast target appears/disappears.
// Content-free logging: verdict + parse-source code only, never netsh output.
func refreshMiracastCapability() {
	ok, src := queryMiracastSupport()
	miraMu.Lock()
	changed := miraCapable != ok || !miraChecked
	miraCapable, miraChecked = ok, true
	miraMu.Unlock()
	if changed {
		logf("cast miracast capability: %v (%s)", ok, src)
		castScan.refresh()
	}
}

// queryMiracastSupport parses `netsh wlan show drivers` (§2.1: Miracast is
// Wi-Fi Direct — an Ethernet-only box has none). Parse strategy, in order,
// all matching case-insensitive:
//  1. exec failure (incl. wlansvc absent)  -> unsupported          ("execfail")
//  2. the "Wireless Display Supported" line: verdict = first token after the
//     colon, yes/no                        -> that verdict          ("line")
//  3. sub-flag form — some builds bury the verdict in the parenthetical
//     "(Graphics Driver: Yes, Wi-Fi Driver: Yes)" (the Wi-Fi flag is the
//     NDIS 6.4 wireless-display driver check): both yes -> supported; flags
//     present otherwise -> unsupported                              ("subflags")
//  4. nothing recognizable (section absent on Ethernet-only boxes, or fully
//     localized output)                    -> unsupported           ("none")
//
// Known limitation: fully localized netsh output (label AND yes/no tokens
// translated) lands in case 4 = unsupported. Fail-closed by design.
func queryMiracastSupport() (capable bool, src string) {
	cmd := exec.Command("netsh", "wlan", "show", "drivers")
	// No console flash — the host is built with -H windowsgui.
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	out, err := cmd.Output()
	if err != nil {
		return false, "execfail"
	}
	text := strings.ToLower(string(out))
	for _, line := range strings.Split(text, "\n") {
		if !strings.Contains(line, "wireless display supported") {
			continue
		}
		if _, val, ok := strings.Cut(line, ":"); ok {
			val = strings.TrimSpace(val)
			if strings.HasPrefix(val, "yes") {
				return true, "line"
			}
			if strings.HasPrefix(val, "no") {
				return false, "line"
			}
		}
		break // found the line but couldn't read the verdict — try sub-flags
	}
	if strings.Contains(text, "graphics driver: yes") && strings.Contains(text, "wi-fi driver: yes") {
		return true, "subflags"
	}
	if strings.Contains(text, "graphics driver:") || strings.Contains(text, "wi-fi driver:") {
		return false, "subflags"
	}
	return false, "none"
}

// --- The one native cast session (§10.1: one per host, process-global) --------

// A castSession is never torn down by a dropping phone connection — only by
// cast.stop, the tray Stop, guided-window expiry, the topology watcher seeing
// the mirror end, or host quit.
type castSession struct {
	sid         string
	state       string // "starting" | "casting" (stopped clears castCur)
	stage       string // "launching" | "guided" | "" once casting
	targetId    string
	targetName  string
	quality     string
	startedAt   int64
	guidedUntil time.Time
	stop        chan struct{}
}

var (
	castMu  sync.Mutex
	castCur *castSession
	castSeq int
)

const (
	castGuidedWindow = 120 * time.Second // §8.8 guided-fallback window
	vkK              = 0x4B
)

// castStart handles cast.start. Miracast only this slice: we open the Win+K
// Connect flyout but cannot select the sink by name headlessly, so the start
// is immediately the GUIDED path (§8.7 nomirror, same-room, non-terminal) —
// the phone shows the numbered sheet and the topology watcher flips the
// session to casting when the user completes the mirror.
func castStart(cs *connState, m msg) {
	rid := m.Rid
	switch m.Target.Type {
	case "miracast":
	case "cast", "airplay":
		cs.send(map[string]any{"t": "cast.err", "rid": rid, "code": "unsupported", "relaunch": false,
			"msg": "This computer can cast via Wireless display (Miracast). Chromecast casting from Windows arrives in a later update."})
		logf("cast start rejected: unsupported type")
		return
	default:
		cs.send(map[string]any{"t": "cast.err", "rid": rid, "code": "unsupported", "relaunch": false,
			"msg": "Unknown cast target type."})
		logf("cast start rejected: unknown type")
		return
	}
	if !miracastAvailable() {
		cs.send(map[string]any{"t": "cast.err", "rid": rid, "code": "unsupported", "relaunch": false,
			"msg": "This PC doesn't support Miracast — it needs a Wi-Fi adapter with Wi-Fi Direct."})
		logf("cast start rejected: no capability")
		return
	}

	castMu.Lock()
	if castCur != nil {
		if castCur.targetId == m.Target.Id {
			state := castStateMsgLocked()
			castMu.Unlock()
			cs.send(state) // idempotent re-start of the same target (§10.1)
			return
		}
		castMu.Unlock()
		cs.send(map[string]any{"t": "cast.err", "rid": rid, "code": "busy", "relaunch": false,
			"msg": "Already casting to another screen."})
		logf("cast start rejected: busy")
		return
	}
	castSeq++
	name := castScan.targetName(m.Target.Id)
	if name == "" {
		name = miracastTargetName
	}
	quality := m.Quality
	if quality == "" {
		quality = "auto"
	}
	s := &castSession{
		sid:         "s" + strconv.Itoa(castSeq),
		state:       "starting",
		stage:       "launching",
		targetId:    m.Target.Id,
		targetName:  name,
		quality:     quality,
		guidedUntil: time.Now().Add(castGuidedWindow),
		stop:        make(chan struct{}),
	}
	castCur = s
	castMu.Unlock()
	logf("cast session %s: starting (launching)", s.sid)

	// First response ≤2 s (§8.1) — the rid-bearing status, to the requester.
	cs.send(map[string]any{"t": "cast.status", "sid": s.sid, "rid": rid, "state": "starting", "stage": "launching"})

	winKTap()
	// nomirror is sent with sid only, NO rid: the rid was already consumed by
	// the first rid-bearing cast.status above (§8.1 — "rid present only on the
	// first status answering a cast.start"). Re-using it here makes the phone
	// treat this guided err as a stale start attempt and drop it (mirrors the
	// Mac host's enterGuided, which likewise omits rid). This guided nomirror
	// is same-room, non-terminal (§8.7): the phone shows the numbered sheet.
	cs.send(map[string]any{"t": "cast.err", "sid": s.sid, "code": "nomirror", "relaunch": false,
		"msg": "Pick your TV in the Connect panel — it's open on your computer."})
	// Tray/power updates happen under castMu everywhere so a racing teardown
	// can never leave a stale "Casting…" row or a leaked assertion behind.
	castMu.Lock()
	ended := castCur != s
	if !ended {
		s.stage = "guided"
		trayCastUpdate(true, s.targetName)
	}
	castMu.Unlock()
	if ended {
		return // torn down while we were launching
	}
	logf("cast session %s: starting (guided)", s.sid)
	go castRun(s)
}

// castRun is the per-session watcher/status loop: every 1 s it checks the
// display topology and broadcasts cast.status — state/target only for NATIVE
// (§8.7), transitions-only logging.
func castRun(s *castSession) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
		}
		active, ok := miracastPathActive()
		now := time.Now()

		castMu.Lock()
		if castCur != s {
			castMu.Unlock()
			return
		}
		end := ""
		switch {
		case s.state == "starting" && ok && active:
			s.state, s.stage = "casting", ""
			s.startedAt = now.Unix()
			powerAssert(true)
			logf("cast session %s: casting", s.sid)
		case s.state == "starting" && now.After(s.guidedUntil):
			end = "user" // guided window expired — nobody completed the mirror
		case s.state == "casting" && ok && !active:
			end = "user" // mirror ended outside the app (flyout Disconnect, TV off)
		}
		status := map[string]any{"t": "cast.status", "sid": s.sid, "state": s.state, "target": s.targetName}
		if s.stage != "" {
			status["stage"] = s.stage
		}
		castMu.Unlock()

		if end != "" {
			castTeardown(s, end)
			return
		}
		castBroadcast(status)
	}
}

// castTeardown is the single teardown path (§10.6, native subset): stop the
// watcher, release the power assertion, notify stopped, clear the tray row.
// The OS mirror itself is NOT scripted off this slice — Windows has no safe
// non-WinRT disconnect (forcing SetDisplayConfig topology would disturb
// multi-monitor desktops); the flyout stays one Win+K away.
func castTeardown(s *castSession, reason string) {
	castMu.Lock()
	if castCur != s {
		castMu.Unlock()
		return
	}
	castCur = nil
	close(s.stop)
	powerAssert(false)
	trayCastUpdate(false, "")
	castMu.Unlock()

	castBroadcast(map[string]any{"t": "cast.status", "sid": s.sid, "state": "stopped", "reason": reason})
	logf("cast session %s: stopped (%s)", s.sid, reason)
}

// castStop handles cast.stop from any hello-completed connection (§10.1).
func castStop(cs *connState, m msg) {
	castMu.Lock()
	s := castCur
	castMu.Unlock()
	if s == nil || (m.Sid != "" && m.Sid != s.sid) {
		return
	}
	castTeardown(s, "user")
}

// castStateOnHello pushes the session snapshot right after a completed hello
// (§8.4 re-attach) — a reconnecting phone restores its casting bar from it.
func castStateOnHello(cs *connState) {
	castMu.Lock()
	if castCur == nil {
		castMu.Unlock()
		return
	}
	state := castStateMsgLocked()
	castMu.Unlock()
	cs.send(state)
}

func castStateMsgLocked() map[string]any {
	s := castCur
	m := map[string]any{
		"t": "cast.state", "sid": s.sid, "state": s.state, "path": "native",
		"target": map[string]any{"id": s.targetId, "name": s.targetName, "type": "miracast"},
		// The native OS mirror always carries system audio; display selection
		// is the OS's (no displays enumeration this slice).
		"audio": true, "quality": s.quality,
	}
	if s.startedAt != 0 {
		m["startedAt"] = s.startedAt
	}
	return m
}

// castShutdown tears down the active session, if any — the tray Stop row and
// the tray exit hook both land here.
func castShutdown() {
	castMu.Lock()
	s := castCur
	castMu.Unlock()
	if s != nil {
		castTeardown(s, "user")
	}
}

// winKTap opens the Win+K Connect flyout: hold VK_LWIN, tap K, release.
func winKTap() {
	sendKbd(vkLWin, 0, 0)
	keyTap(vkK)
	sendKbd(vkLWin, 0, keyeventfKeyup)
}

// --- Power assertion (§10.4) ---------------------------------------------------

// Execution-state flags (winbase.h).
const (
	esContinuous      = 0x80000000
	esDisplayRequired = 0x00000002
)

var (
	powerMu   sync.Mutex
	powerStop chan struct{} // non-nil while the assertion is held
)

// powerAssert holds/releases the no-display-sleep assertion while casting.
// SetThreadExecutionState is per-THREAD and goroutines migrate, so the
// assertion lives on a dedicated locked OS thread that clears the flags
// (ES_CONTINUOUS alone) before exiting on release.
func powerAssert(on bool) {
	powerMu.Lock()
	defer powerMu.Unlock()
	if on {
		if powerStop != nil {
			return
		}
		stop := make(chan struct{})
		powerStop = stop
		go func() {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			procSetThreadExecutionState.Call(uintptr(esContinuous | esDisplayRequired))
			<-stop
			procSetThreadExecutionState.Call(uintptr(esContinuous))
		}()
		return
	}
	if powerStop != nil {
		close(powerStop)
		powerStop = nil
	}
}

// --- Display-topology watcher ---------------------------------------------------

// QueryDisplayConfig struct layout (winuser.h/wingdi.h, x64 — every field is
// 4-byte aligned, no padding):
//
//	DISPLAYCONFIG_PATH_SOURCE_INFO = LUID adapterId(8) + id(4) + modeInfoIdx(4)
//	                                 + statusFlags(4)                  = 20 B
//	DISPLAYCONFIG_PATH_TARGET_INFO = LUID adapterId(8) + id(4) + modeInfoIdx(4)
//	                                 + outputTechnology(4) @ offset 16
//	                                 + rotation(4) + scaling(4)
//	                                 + refreshRate(4+4) + scanLineOrdering(4)
//	                                 + targetAvailable(4) + statusFlags(4) = 48 B
//	DISPLAYCONFIG_PATH_INFO        = source(20) + target(48) + flags(4)   = 72 B
//	  -> targetInfo.outputTechnology at path offset 20+16 = 36
//	DISPLAYCONFIG_MODE_INFO        = 64 B, 8-byte aligned (UINT64 pixelRate
//	  in the union) — opaque here, only the path array is inspected.
//
// DISPLAYCONFIG_OUTPUT_TECHNOLOGY_MIRACAST = 15.
const (
	qdcOnlyActivePaths       = 0x00000002
	outputTechnologyMiracast = 15
	errorSuccess             = 0
	errorInsufficientBuffer  = 122
)

type dcPathInfo struct {
	_                [36]byte // sourceInfo(20) + targetInfo adapterId/id/modeInfoIdx(16)
	outputTechnology uint32
	_                [32]byte // rotation..statusFlags(28) + path flags(4)
}

type dcModeInfo struct{ _ [8]uint64 } // opaque, keeps the 8-byte alignment

// Compile-time layout guards: a negative array length breaks the build if the
// prefix layout ever drifts from 72 bytes.
var (
	_ [72 - unsafe.Sizeof(dcPathInfo{})]byte
	_ [unsafe.Sizeof(dcPathInfo{}) - 72]byte
)

var dcFailLogged sync.Once

// miracastPathActive reports whether any active display path drives a Miracast
// output. ok=false means the query itself failed — the watcher skips detection
// for that tick rather than guessing.
func miracastPathActive() (active, ok bool) {
	for attempt := 0; attempt < 3; attempt++ {
		var nPaths, nModes uint32
		r, _, _ := procGetDisplayConfigBufferSizes.Call(qdcOnlyActivePaths,
			uintptr(unsafe.Pointer(&nPaths)), uintptr(unsafe.Pointer(&nModes)))
		if r != errorSuccess {
			break
		}
		if nPaths == 0 {
			return false, true
		}
		paths := make([]dcPathInfo, nPaths)
		modes := make([]dcModeInfo, nModes+1) // +1: never hand the API a nil pointer
		r, _, _ = procQueryDisplayConfig.Call(qdcOnlyActivePaths,
			uintptr(unsafe.Pointer(&nPaths)), uintptr(unsafe.Pointer(&paths[0])),
			uintptr(unsafe.Pointer(&nModes)), uintptr(unsafe.Pointer(&modes[0])), 0)
		if r == errorInsufficientBuffer {
			continue // topology changed between the two calls — re-size and retry
		}
		if r != errorSuccess {
			break
		}
		for i := 0; i < int(nPaths) && i < len(paths); i++ {
			if paths[i].outputTechnology == outputTechnologyMiracast {
				return true, true
			}
		}
		return false, true
	}
	dcFailLogged.Do(func() { logf("cast topology query failed") })
	return false, false
}
