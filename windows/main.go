// Remotype Host for Windows — receives keyboard/trackpad input from the Remotype
// phone app over the LAN and injects it with SendInput. Protocol v2 adds the
// handshake reply, the Spotlight overlay, and the hello-gated control events
// (clipboard bridge, vitals stream, open-app). See PROTOCOL.md. The cast
// subsystem (cast.* — discovery.go, cast_windows.go) is specced in docs/CASTING.md.
//
// Build (from any OS):  GOOS=windows GOARCH=amd64 go build -o remotype-host.exe
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/grandcat/zeroconf"
)

// Protocol version this host speaks. Sent back in the `hi` handshake reply.
const protocolVersion = 2

// App metadata (shown in the tray About box).
const (
	appName        = "Remotype Host"
	appCompany     = "Custavia"
	appVersion     = "1.1.0"
	appReleaseDate = "September 2026"
	appSupport     = "support.remotype@custavia.com"
	appTagline     = "Use your phone as a wireless keyboard, trackpad, and Spotlight presenter for this PC — over your Wi-Fi, no cables."
)

// Live server state (read by the tray's About box + Re-advertise action).
var (
	hostName   string
	listenPort int
	zcServer   *zeroconf.Server
	zcMu       sync.Mutex
)

// Clipboard cap (UTF-8 bytes), both directions — matches PROTOCOL.md + the Mac host.
const clipMaxBytes = 64 * 1024

// Modifier bits, shared with the phone (see PROTOCOL.md).
const (
	modCtrl  = 1
	modShift = 2
	modAlt   = 4
	modGUI   = 8
)

// One protocol message (a superset of all event fields).
type msg struct {
	T string `json:"t"`
	V int    `json:"v"` // hello: client protocol version
	C string `json:"c"`
	K string `json:"k"`
	S string `json:"s"`
	// ovl.timer — audience countdown (§Presenter).
	On   bool `json:"on"`
	Secs int  `json:"secs"`
	Warn bool `json:"warn"`
	Del  int  `json:"del"`
	B    int  `json:"b"`
	Down bool `json:"down"`
	// float64, not int: `mm`/`sc` send whole numbers, but `tv.pan` sends
	// normalized display-FRACTION deltas (e.g. 0.02). An int field would make
	// json.Unmarshal reject the whole tv.pan frame and silently drop it. Integers
	// decode into float64 losslessly, so mm/sc just cast back at the call site.
	Dx   float64 `json:"dx"`
	Dy   float64 `json:"dy"`
	D    int     `json:"d"`
	Mods int     `json:"mods"`
	U    string  `json:"u"`
	Name string  `json:"name"`
	Size int     `json:"size"`
	Seq  int     `json:"seq"`
	Data string  `json:"data"`
	Id   flexID  `json:"id"`  // clip.get int correlation id OR cast.display string id
	App  string  `json:"app"` // open: app name
	// Spotlight overlay (ovl.*) — see PROTOCOL.md "Spotlight overlay (v2)".
	M   string  `json:"m"`   // ovl.mode sub-mode: spotlight|square|pointer|annotate|off
	Rf  float64 `json:"rf"`  // cutout/dot radius as a fraction of the shorter screen side
	Dim int     `json:"dim"` // backdrop dim 0..100
	Col string  `json:"col"` // 6-hex RGB for pointer dot / ink
	X   float64 `json:"x"`   // normalized 0..1, origin TOP-LEFT, y down
	Y   float64 `json:"y"`   // normalized 0..1, origin TOP-LEFT, y down
	P   string  `json:"p"`   // ovl.ink phase: down|move|up
	// TV / screen-mirror lens (tv.*) — see docs/PROTOCOL.md "TV mode (v2)".
	W  int     `json:"w"`  // tv.sub output width  (px)
	H  int     `json:"h"`  // tv.sub output height (px)
	Z  float64 `json:"z"`  // tv.sub / tv.zoom magnification (1 = whole FOV)
	Sq int     `json:"sq"` // tv.point: the lens sequence the finger was touching (0 = none yet).
	//        NOT "s" — that key is already the `text` payload string on this flat struct.
	F string `json:"f"` // tv.sub / tv.follow mode: auto|cursor|caret|full
	// MCM edge-flow (edge.*) — see docs/MCM.md §3.
	Sides []string `json:"sides"` // edge.arm: which edges lead to a neighbor
	To    string   `json:"to"`    // edge.release: edge being left
	From  string   `json:"from"`  // edge.enter: edge the cursor arrives on
	// Casting (cast.*) — see docs/CASTING.md §8.
	Sid     string  `json:"sid"`     // cast session id
	Rid     string  `json:"rid"`     // cast request correlation id
	Target  castRef `json:"target"`  // cast.start target reference
	Addr    string  `json:"addr"`    // cast.reach probe address
	Port    int     `json:"port"`    // cast.reach probe port
	Quality string  `json:"quality"` // cast.start/quality: auto|low_latency|high_quality
	Display string  `json:"display"` // cast.start display id (optional)
	Code    string  `json:"code"`    // cast.pin code
	Level   float64 `json:"level"`   // cast.volume 0.0-1.0
	// RT1 trust layer (docs/RT1.md). `Name` above doubles as the phone's
	// display name in both the hello and pair.begin.
	RT   int    `json:"rt"`   // protocol marker: present = this peer speaks RT1
	Dev  string `json:"dev"`  // 32 hex, the phone's stable id
	SPK  string `json:"spk"`  // base64 SPKI, the phone's static public key
	EPK  string `json:"epk"`  // base64 SPKI, this handshake's ephemeral key
	Tag  string `json:"tag"`  // hello: SHA256(LP("RT1-TAG") ‖ LP(n) ‖ LP(spk))
	N    string `json:"n"`    // hello: the phone's 16-byte nonce, base64
	MAC  string `json:"mac"`  // pair.conf / rt.conf confirmation
	Plat string `json:"plat"` // "ios" | "android"
}

// flexID carries the wire field "id", which is an int for clip.get but a
// string for cast.display. Raw bytes are kept so the clip reply echoes the
// exact form that arrived (an absent id echoes 0, matching the old int zero).
type flexID struct{ raw json.RawMessage }

func (f *flexID) UnmarshalJSON(b []byte) error { f.raw = append(f.raw[:0], b...); return nil }
func (f flexID) MarshalJSON() ([]byte, error) {
	if len(f.raw) == 0 {
		return []byte("0"), nil
	}
	return f.raw, nil
}

// castRef is the target reference carried by cast.start (docs/CASTING.md §8.4).
type castRef struct {
	Id   string `json:"id"`
	Type string `json:"type"`
	Addr string `json:"addr"`
	Port int    `json:"port"`
}

// Process-wide overlay controller. There is one overlay window for the host; a
// new connection re-targets/resets it rather than creating its own.
var overlay = newOverlay()

func main() {
	initLog()
	// Before the socket opens: prove this build's RT1 agrees with the frozen
	// spec. A drift between the Go, Swift and Kotlin implementations shows up in
	// the field as "connects, then dies, on one platform only" — this turns that
	// into one line in host.log.
	rt1SelfTest()
	go inputTel.runFlush() // per-second jitter telemetry into host.log
	startServer()
	// Startup Miracast capability probe (async, cast_windows.go).
	castInit()
	// Open the setup wizard rather than leaving a new user staring at a tray
	// icon they have not found yet, in front of a firewall dialog whose wrong
	// answer is permanent. The gate is "has a phone ever reached this host",
	// not "was the wizard shown once": a shown-once marker survives every way
	// setup can fail (wizard closed early, firewall dialog answered wrong,
	// reinstall over stale state), and each of those used to mean the next
	// launch explained nothing. Until a phone gets through, the wizard IS the
	// product's first experience, so it returns on every launch — and stops
	// forever the moment one connection arrives.
	if needsSetup() {
		go showSetupWizard()
	}

	// runTray() blocks on the platform UI loop (system tray on Windows). The
	// TCP accept loop runs on its own goroutine started in startServer().
	runTray()
}

// initLog routes output to a log file, since the tray build has no console
// (built with -H windowsgui). Falls back to stderr if the file can't open.
func initLog() {
	log.SetFlags(log.LstdFlags)
	dir, err := os.UserConfigDir()
	if err != nil {
		return
	}
	d := filepath.Join(dir, "RemotypeHost")
	if os.MkdirAll(d, 0o755) != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(d, "host.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err == nil {
		log.SetOutput(f)
	}
}

func logf(format string, a ...any) {
	log.Printf(format, a...)
	// Mirror into the tray's on-demand activity console (windows: activity_windows.go).
	activityLog(fmt.Sprintf(format, a...))
}

// preferredPort is the well-known Remotype Host port (matches the phone clients'
// DEFAULT_HOST_PORT / defaultHostPort). Binding it gives Connect-by-IP + Tailscale
// a stable address and a stable firewall rule; if it's taken we fall back to an
// ephemeral port and rely on mDNS discovery (parity with the macOS host).
const preferredPort = 50808

// startServer binds the TCP listener, advertises over mDNS, and starts accepting
// connections on a background goroutine.
func startServer() {
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", preferredPort))
	if err != nil {
		ln, err = net.Listen("tcp", ":0") // 50808 taken → ephemeral + mDNS
	}
	if err != nil {
		logf("Could not listen: %v", err)
		os.Exit(1)
	}
	listenPort = ln.Addr().(*net.TCPAddr).Port
	hostName, _ = os.Hostname()
	advertise()
	go advertiseWatchdog()
	logf("Remotype Host running. Listening on port %d, advertising _hsbtk._tcp.", listenPort)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				continue
			}
			go handle(conn)
		}
	}()
}

// advertise (re)registers the Bonjour service. Re-advertising shuts down the old
// registration first — used by the tray's "Re-advertise" action when the phone
// can't discover the host.
func advertise() {
	zcMu.Lock()
	defer zcMu.Unlock()
	if zcServer != nil {
		zcServer.Shutdown()
		zcServer = nil
	}
	// os TXT lets the phone show a platform glyph in the host list BEFORE any
	// connection exists (the hi message only names the platform after connect).
	s, err := zeroconf.Register("Remotype Host ("+hostName+")", "_hsbtk._tcp", "local.", listenPort, []string{"os=windows"}, nil)
	if err != nil {
		logf("mDNS registration failed (the phone may not auto-discover): %v", err)
		return
	}
	zcServer = s
}

func reAdvertise() {
	advertise()
	logf("re-advertised _hsbtk._tcp on the network")
}

// advertiseWatchdog keeps the Bonjour registration alive for the life of the
// process.
//
// zeroconf.Register binds its multicast sockets to the interfaces that exist at
// the moment it is called, and it does NOT re-bind afterwards. So any change
// underneath it — Wi-Fi dropping and reconnecting, the machine sleeping and
// waking, a VPN adapter (Tailscale) coming up or going away, docking — leaves
// the registration answering on sockets that no longer carry traffic. The
// service goes silent, the phone stops discovering the PC, and the only cure
// was the tray's "Re-advertise on network". That is the bug this closes.
//
// Three independent signals, because they fail differently:
//   - the interface address set changed (the common case: new/lost IP)
//   - the wall clock jumped far more than the tick (the machine slept)
//   - nothing happened for a long while (backstop for a socket that died
//     quietly with the address set unchanged)
func advertiseWatchdog() {
	const tick = 15 * time.Second
	const backstop = 10 * time.Minute

	last := ifaceFingerprint()
	lastAdv := time.Now()
	for {
		before := time.Now()
		time.Sleep(tick)
		now := time.Now()

		// A tick that took hugely longer than it was asked to means the process
		// was suspended — i.e. the machine slept — and the sockets are stale.
		slept := now.Sub(before) > 4*tick

		fp := ifaceFingerprint()
		switch {
		case fp != last:
			logf("network changed (%s -> %s) — re-advertising", last, fp)
			last = fp
			advertise()
			lastAdv = now
		case slept:
			logf("woke from sleep — re-advertising")
			advertise()
			lastAdv = now
		case now.Sub(lastAdv) >= backstop:
			advertise()
			lastAdv = now
		}
	}
}

// ifaceFingerprint is a stable string of every usable non-loopback unicast
// address, so any add/remove/renumber shows up as a plain string inequality.
func ifaceFingerprint() string {
	ifs, err := net.Interfaces()
	if err != nil {
		return "?"
	}
	var addrs []string
	for _, in := range ifs {
		if in.Flags&net.FlagUp == 0 || in.Flags&net.FlagLoopback != 0 {
			continue
		}
		aa, err := in.Addrs()
		if err != nil {
			continue
		}
		for _, a := range aa {
			addrs = append(addrs, in.Name+"="+a.String())
		}
	}
	sort.Strings(addrs)
	return strings.Join(addrs, ",")
}

// connState is per-connection: the reply writer (guarded by mu since the vitals
// goroutine also writes), the negotiated protocol version (0 until a v2 hello on
// THIS connection — the gate for clip/vitals/open/ovl/cast), the vitals stream,
// and the cast-scan subscription.
type connState struct {
	mu sync.Mutex
	w  *bufio.Writer
	// rt1 is this connection's trust state. Every field on it is read or
	// written under mu: the read goroutine advances the handshake and the
	// receive counter, while send (called from the vitals, TV and cast
	// goroutines too) advances the send counter.
	rt1        rt1State
	version    int
	vitalsStop chan struct{}
	// castScanSubscribed marks whether this connection holds a cast.scan.sub;
	// it gates duplicate sub/unsub. It is a plain flag, not a stop channel —
	// the shared browse loop's real stop lives in castScanner.stop. Accessed
	// only from this connection's read goroutine (dispatch + handle's defer).
	castScanSubscribed bool
}

// send writes one newline-delimited frame to the phone (thread-safe). Once the
// session is open the frame is a base64 sealed blob rather than JSON; the
// newline framing itself never changes, which is what let RT1 land without
// touching the read loop's buffering or any of the teardown paths.
func (cs *connState) send(obj map[string]any) { cs.sendFrame(obj, false) }

// sendPlaintext is for exactly one frame — rt.ok, the host's last unsealed line
// (RT1 §3). By the time it is written the session is already open, so without
// this the frame would be sealed with counter 0 and the phone, still reading
// plaintext, would see line noise.
func (cs *connState) sendPlaintext(obj map[string]any) { cs.sendFrame(obj, true) }

func (cs *connState) sendFrame(obj map[string]any, plaintext bool) {
	data, err := json.Marshal(obj)
	if err != nil {
		return
	}
	cs.mu.Lock()
	defer cs.mu.Unlock()
	if cs.rt1.isOpen() && !plaintext {
		// Sealing happens HERE, under the write lock, and nowhere else: the
		// counter is sequential, and two goroutines sealing concurrently would
		// reach the phone out of counter order and break its decryption
		// permanently — not just for those frames.
		sealed, err := cs.rt1.seal(data)
		if err != nil {
			logf("RT1: could not seal an outbound frame: %v", err)
			return
		}
		data = sealed
	}
	cs.w.Write(data)
	cs.w.WriteByte('\n')
	cs.w.Flush()
}

// --- RT1 helpers. Each takes mu for the shortest possible span: the read
// goroutine must NOT hold it across dispatch, which calls send.

func (cs *connState) rt1IsOpen() bool {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.rt1.isOpen()
}

func (cs *connState) rt1OpenLine(line []byte) ([]byte, error) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.rt1.open(line)
}

func handle(conn net.Conn) {
	defer conn.Close()
	defer releaseAllModifiers()
	// A dropped/backgrounded phone must never leave the screen dimmed/inked or a
	// vitals stream running: always clean up when this connection ends.
	defer overlay.Reset()

	cs := &connState{w: bufio.NewWriter(conn)}
	defer cs.stopVitals()
	defer edgeDisarm(cs) // stop MCM edge polling on disconnect (no leaked timer)
	// A dropped/backgrounded phone must not leave the screen-mirror capture
	// goroutine running (it would keep grabbing + encoding the screen forever).
	defer tvStop(cs)
	// A dropped phone detaches from cast pushes and its scan subscription —
	// but the cast SESSION is process-global and deliberately survives this
	// (docs/CASTING.md §10.2: the host↔sink mirror is independent of the link).
	defer cs.stopCastScan()
	defer castDetach(cs)

	logf("Phone connected: %s", conn.RemoteAddr())
	// The setup wizard's only honest proof that the firewall is out of the way:
	// nothing on this machine can be asked whether a BLOCK rule exists (netsh's
	// output is localized, and the COM policy API is a long way from here), but
	// a phone that got a TCP connection through is the answer to the question
	// the firewall step is really asking.
	setupNotePhoneReached()
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if cs.rt1IsOpen() {
			plain, err := cs.rt1OpenLine(line)
			if err != nil {
				// A line that will not decrypt means the peer is out of step
				// or someone is probing. Close, silently: a distinguishable
				// error frame here would be a decryption oracle.
				logf("RT1: sealed line failed to open — closing")
				return
			}
			line = plain
		}
		var m msg
		if err := json.Unmarshal(line, &m); err != nil {
			continue
		}
		if handleHandshake(m, cs) {
			continue
		}
		dispatch(m, cs)
	}
	// The socket that began a pairing went away before finishing it, and
	// without a pair.cancel — a drop, not a decision. Same outcome for the
	// code, gentler words.
	cs.mu.Lock()
	droppedMidPairing := cs.rt1.isPairing()
	cs.mu.Unlock()
	if droppedMidPairing && pairing.live() != "" {
		pairing.endedByPhone("The phone disconnected before pairing finished", "phone disconnected mid-pairing")
	}
	hostNoteSessionClosed()
	logf("Phone disconnected.")
}

// dispatch routes one parsed message. Input events (key/mouse/etc.) and the
// handshake are ungated; the v2 control events (clipboard/vitals/open/overlay)
// require a completed v2 `hello` on this same connection (PROTOCOL.md security
// note). Unknown `t` is a safe no-op.
// handleHandshake answers the only messages accepted before a connection is
// open. It returns true when the line was a handshake message and must go no
// further.
//
// `hello` deliberately returns false: it is the start of the session handshake
// but the existing code in dispatch already knows how to answer one, so the RT1
// fields are handled there instead of duplicating the capability reply.
func handleHandshake(m msg, cs *connState) bool {
	switch m.T {
	case "pair.begin":
		// Raise the window on EVERY pair.begin, not only when no code is live.
		// showPairingWindow is idempotent — a live code is brought forward, not
		// replaced — and a phone re-tapping the PC is exactly the moment the
		// user is looking for the window: if it is buried behind a terminal
		// (Windows refuses SetForegroundWindow from a background process), this
		// is what brings it back up. The old "only when code == \"\"" left a
		// buried window buried no matter how many times the phone asked.
		showPairingWindow()
		// READ THE CODE AFTER SHOWING. This handler used to carry on with the
		// empty string it had tested a line earlier, so the host's transcript
		// was built on "" while the screen showed a real code — no code the
		// user typed could ever match. Every unattended first connect hit it.
		code := pairing.live()
		host, _ := os.Hostname()
		cs.mu.Lock()
		reply := cs.rt1.beginPairing(m.Dev, m.SPK, m.EPK, m.Name, m.Plat, code, host)
		cs.mu.Unlock()
		cs.send(reply)
		return true

	case "pair.cancel":
		// The user tapped Cancel on the phone. Retire the code and SAY SO on
		// the PC: a window still showing a code nobody is typing reads as
		// "still waiting", when the truth is that the phone walked away.
		cs.mu.Lock()
		pairingHere := cs.rt1.isPairing()
		cs.rt1.cancelPairing()
		cs.mu.Unlock()
		if pairingHere {
			pairing.endedByPhone("Pairing was cancelled on phone", "cancelled on the phone")
		}
		return true

	case "pair.conf":
		cs.mu.Lock()
		reply, paired := cs.rt1.confirmPairing(m.MAC)
		cs.mu.Unlock()
		if paired != nil {
			pairing.noteSuccess(paired.Name)
		} else {
			pairing.noteFailure()
		}
		cs.send(reply)
		return true

	case "rt.conf":
		cs.mu.Lock()
		reply := cs.rt1.confirmSession(m.MAC)
		opened := cs.rt1.isOpen()
		name := ""
		if cs.rt1.device != nil {
			name = cs.rt1.device.Name
		}
		cs.mu.Unlock()
		// rt.ok is the host's LAST plaintext line (RT1 §3) — the phone is still
		// reading in the clear when it arrives.
		cs.sendPlaintext(reply)
		if opened {
			hostNoteSessionOpen(name)
			logf("RT1: session open with %s", name)
			// Everything the old hello used to trigger, now that the peer has
			// actually proved who it is.
			if cs.version >= 2 {
				castAttach(cs)
			}
		}
		return true
	}
	return false
}

// dispatch routes one parsed message.
//
// THE GUARD is the first thing in it, and it is the reason RT1 exists: before
// it, every case below was reachable by anything that could open a TCP
// connection to this port. It has to sit here, above the switch, because the
// messages that mattered most were the ones handled EARLIEST — a check inside
// the switch would have covered none of them.
func dispatch(m msg, cs *connState) {
	if !cs.rt1IsOpen() && m.T != "hello" && m.T != "ping" {
		// Two exceptions, and the second is not a convenience — it is a bug fix.
		// `hello` IS the start of the handshake. `ping` is pure liveness and
		// grants nothing, and DROPPING it broke pairing: the phone pings every
		// 5 s, gets no pong from a connection that has not yet paired, and its
		// watchdog concludes the link is dead and tears it down — while the user
		// is still reading the code off the screen. Typing the code fast enough
		// beat the watchdog, which is why a wrong code could report "didn't
		// match" while a correct one, typed a minute later, hung forever.
		logf("RT1: dropped a message from an unauthenticated connection")
		return
	}
	inputTel.maybeArrival(m.T) // jitter telemetry (input_telemetry.go)
	switch m.T {
	case "ping":
		// Liveness probe (PROTOCOL.md): lets the phone distinguish a half-open
		// TCP link (doze, AP roam) from a healthy quiet one. Reply-only.
		cs.send(map[string]any{"t": "pong"})
	case "hello":
		cs.version = m.V
		logf("Hello from %s", m.Name)
		setupNotePhoneNamed(m.Name)
		host, _ := os.Hostname()
		// cast:1 = cast-protocol version (docs/CASTING.md §8.1) — its absence tells
		// the phone this host predates casting. tv:1 = this host can stream its
		// screen (screen-mirror capable); the phone hides TV mode against a host
		// that omits it, instead of spinning on a picture that never arrives.
		// `os` lets the phone reason about capabilities that predate an explicit
		// flag. Note we deliberately do NOT send `audio`: this host has no
		// computer-audio capture, so the phone hides those modes.
		hi := map[string]any{"t": "hi", "v": protocolVersion, "name": host, "os": "windows", "cast": 1}
		if tvSupported() {
			hi["tv"] = 1
		}

		if m.RT != 0 {
			// An RT1 phone puts its device tag, nonce and ephemeral key on the
			// hello, so the session handshake costs no extra round trip.
			cs.mu.Lock()
			fields, failure := cs.rt1.beginSession(m.Tag, m.N, m.EPK)
			cs.mu.Unlock()
			if failure != nil {
				// Unknown device: answer honestly and let the phone offer to
				// pair. Do NOT fall back to an open connection.
				cs.send(failure)
				return
			}
			for k, v := range fields {
				hi[k] = v
			}
			cs.send(hi)
			// castAttach waits for rt.conf — see handleHandshake.
			return
		}

		// No RT1 in the hello. Answer it anyway — an unanswered hello leaves an
		// older phone hanging on its legacy timer — but the connection stays
		// UNAUTHENTICATED, so the guard at the top of dispatch drops everything
		// that follows. `rt` and `hid` ride along so an RT1-capable phone that
		// simply has no pairing yet can see what to do next instead of guessing.
		cs.mu.Lock()
		cs.rt1.markLegacy()
		cs.mu.Unlock()
		// Surface it on the PC, because the phone cannot be told: a phone old
		// enough to skip RT1 is old enough to ignore any field explaining why
		// nothing works. Without this the user sees a phone that says
		// "connected" and does nothing, on both screens, with no explanation on
		// either.
		trayLegacyPhone(m.Name)
		logf("RT1: %s connected without RT1 — refusing input until it pairs", m.Name)
		hi["rt"] = rt1Version
		hi["hid"] = identity.hostID
		cs.send(hi)
		return

	// --- Ungated input injection (gated only on OS injection rights) ---
	case "mod":
		setModifierHeld(m.B, m.Down)
		return
	case "key":
		if m.C != "" {
			typeChar(m.C, m.Mods)
		} else if m.K != "" {
			pressNamed(m.K, m.Mods)
		}
		return
	case "text":
		for i := 0; i < m.Del; i++ {
			pressNamed("backspace", 0)
		}
		typeString(m.S)
		return
	case "mm":
		ts := time.Now()
		moveMouse(int(m.Dx), int(m.Dy))
		inputTel.inject("mm", time.Since(ts))
		return
	case "mb":
		mouseButton(m.B, m.Down, m.Mods)
		return
	case "mc":
		mouseButton(m.B, true, m.Mods)
		mouseButton(m.B, false, m.Mods)
		return
	case "sc":
		scrollWheel(int(m.Dx), int(m.Dy))
		return
	case "zoom":
		zoom(m.D)
		return
	case "cc":
		consumer(m.U)
		return
	}

	// --- v2 hello gate: everything below requires a v2 hello on this conn ---
	if cs.version < 2 {
		return // silently ignored (see PROTOCOL.md "Security note")
	}

	switch m.T {
	// Spotlight overlay (v2). Not injection-gated — an overlay is just a window.
	case "ovl.mode":
		overlay.SetMode(m.M, m.Rf, m.Dim, m.Col)
	case "ovl.move":
		ts := time.Now()
		overlay.Move(m.X, m.Y)
		inputTel.inject("ovl.move", time.Since(ts))
	case "ovl.ink":
		overlay.Ink(m.P, m.X, m.Y)
	case "ovl.clear":
		overlay.Clear()
	case "ovl.timer":
		// Audience countdown on the presentation display (§Presenter). The phone
		// owns the clock; we only render what it sends.
		overlay.SetTimer(m.On, m.Secs, m.Warn)
	case "ovl.cursor":
		moveCursorNormalized(m.X, m.Y)

	// TV / screen-mirror lens (v2). The host captures a magnified region of its
	// own screen and streams JPEG frames (tv.frame) to the phone; follow/zoom/pan
	// steer the lens live. Screen capture needs no OS permission on Windows.
	case "tv.sub":
		tvStart(cs, m.W, m.H, m.Z, m.F)
	case "tv.unsub":
		tvStop(cs)
	case "tv.follow":
		tvSetFollow(cs, m.F)
	case "tv.zoom":
		tvSetZoom(cs, m.Z)
	case "tv.pan":
		tvPan(cs, m.Dx, m.Dy)
	case "tv.point":
		tvPoint(cs, m.X, m.Y, m.Sq)

	// MCM edge-flow (v2, docs/MCM.md §3). Host detects the real cursor at an armed
	// edge; the phone commits the switch and parks/warps via release/enter.
	case "edge.arm":
		edgeArm(cs, m.Sides)
	case "edge.disarm":
		edgeDisarm(cs)
	case "edge.release":
		edgeRelease(cs, m.To, m.Y)
	case "edge.enter":
		edgeEnter(cs, m.From, m.Y)

	// Clipboard bridge (v2). Contents are never logged.
	case "clip.file.push":
		clipFilePush(cs, m)
	case "clip.file.chunk":
		clipFileChunk_(cs, m)
	case "clip.file.done":
		clipFileDone(cs, m)
	case "clip.file.pull":
		clipFilePull(cs, m)
	case "clip.set":
		if len(m.S) <= clipMaxBytes {
			setClipboardText(m.S)
		}
		logf("clipboard")
	case "clip.get":
		text, ok, tooLarge := getClipboardText()
		reply := map[string]any{"t": "clip", "id": m.Id}
		switch {
		case tooLarge:
			reply["err"] = "toolarge"
		case !ok:
			reply["err"] = "empty"
		default:
			reply["s"] = text
		}
		cs.send(reply)
		logf("clipboard")

	// PC vitals stream (v2).
	case "vitals.sub":
		cs.startVitals()
		logf("vitals subscribed")
	case "vitals.unsub":
		cs.stopVitals()
		logf("vitals unsubscribed")

	// Open app (v2, Macro deck). Failure-only reply.
	case "open":
		name := strings.TrimSpace(m.App)
		if name == "" || len(name) > 64 {
			return
		}
		if !openApp(name) {
			cs.send(map[string]any{"t": "openresult", "ok": false, "app": name})
		}
		logf("open app")

	// Walk-away/proximity lock needs BLE central + RSSI ranging, which the Go
	// host can't do on Windows (WinRT Bluetooth-LE is incompatible) — it stays
	// Mac + iOS only (docs/PROTOCOL.md). Acknowledge-ignore.
	case "prox.arm", "prox.disarm":
		return

	// Casting (v2, docs/CASTING.md §8). The session is process-global — a dropping
	// phone never tears it down; handle() only detaches its connection.
	case "cast.scan.sub":
		cs.startCastScan()
		logf("cast scan subscribed")
	case "cast.scan.unsub":
		cs.stopCastScan()
		logf("cast scan unsubscribed")
	case "cast.reach":
		go castReachReply(cs, m.Addr, m.Port, m.Rid)
	case "cast.start":
		castStart(cs, m)
	case "cast.stop":
		castStop(cs, m)

	// PIN entry is an AirPlay (Mac) flow, and quality/volume/display are
	// stream controls with no native-Miracast lever — acknowledge-ignore
	// this slice, like prox above (m.Id carries the display id when
	// display switching lands).
	case "cast.pin", "cast.quality", "cast.volume", "cast.display":
		return
	}
}

// startVitals begins (or restarts) the 1.5 s vitals stream on this connection.
// The CPU baseline is seeded now so the first frame ~1.5 s later carries a real
// delta (PROTOCOL.md "no immediate frame").
func (cs *connState) startVitals() {
	cs.stopVitals()
	stop := make(chan struct{})
	cs.vitalsStop = stop

	prevIdle, prevTotal, _ := cpuTimes()
	go func() {
		t := time.NewTicker(1500 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				cpu := 0
				if idle, total, ok := cpuTimes(); ok {
					dIdle := idle - prevIdle
					dTotal := total - prevTotal
					prevIdle, prevTotal = idle, total
					if dTotal > 0 {
						b := float64(dTotal-dIdle) / float64(dTotal) * 100
						if b < 0 {
							b = 0
						} else if b > 100 {
							b = 100
						}
						cpu = int(b + 0.5)
					}
				}
				// vol = -1 (unreadable for now → phone omits it); np omitted
				// until SMTC now-playing is wired. CPU/RAM are real.
				cs.send(map[string]any{"t": "vitals", "cpu": cpu, "ram": ramPercent(), "vol": volPercent()})
			}
		}
	}()
}

func (cs *connState) stopVitals() {
	if cs.vitalsStop != nil {
		close(cs.vitalsStop)
		cs.vitalsStop = nil
	}
}

// needsSetup reports whether this install still owes the user the setup
// wizard: true until a phone has reached this host once. A marker FILE rather
// than a registry value so the portable zip behaves like the installed copy —
// the two differ in enough ways already. (The old "setup-shown" marker, written
// the moment the wizard OPENED, is deliberately ignored: it recorded that the
// wizard appeared, not that setup worked.)
func needsSetup() bool {
	if _, err := os.Stat(setupDoneMarker()); err == nil {
		return false
	}
	// Same proof from before this marker existed: an install with paired
	// phones has plainly been through setup — don't rerun the wizard for
	// everyone on update.
	if len(identity.devices) > 0 {
		markSetupDone()
		return false
	}
	return true
}

func setupDoneMarker() string { return filepath.Join(identityDir(), "setup-done") }

// markSetupDone records the one fact the wizard gate cares about: a phone got
// through. Failure to write is logged and otherwise ignored — nagging once a
// launch is a smaller failure than never explaining the firewall dialog.
func markSetupDone() {
	if err := os.WriteFile(setupDoneMarker(), []byte("1"), 0o644); err != nil {
		logf("could not record setup completion: %v", err)
	}
}
