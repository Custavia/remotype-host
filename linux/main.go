// Remotype Host for Linux — receives keyboard/trackpad input from the Remotype
// phone app over the LAN and injects it through the kernel's uinput device, so
// it works under BOTH X11 and Wayland (the whole reason this host exists rather
// than reusing an X11-only XTEST path).
//
// Build (from any OS):  GOOS=linux GOARCH=amd64 go build -o dist/remotype-host-linux .
// Run (Linux):          ./dist/remotype-host-linux   (needs access to /dev/uinput — see README)
//
// Every connection is subject to RT1 (docs/RT1.md): nothing is injected until
// the peer has proved it is a phone paired at this computer with an on-screen
// code, and every frame after that handshake is sealed. The trust layer itself
// (rt1.go, rt1session.go, identity.go, pairing.go) is shared with the Windows
// host file for file; only the surface that shows the code is Linux-specific.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/grandcat/zeroconf"
)

// Modifier bits, shared with the iOS/Android apps (see docs/PROTOCOL.md).
const (
	modCtrl  = 1
	modShift = 2
	modAlt   = 4
	modGUI   = 8 // GUI = Super/Meta on Linux
)

// protocolVersion is the handshake version this host speaks (v2).
const protocolVersion = 2

// preferredPort is the well-known Remotype Host port (matches the phone
// clients' default). Binding it gives Connect-by-IP and VPN setups a stable
// address; if it is taken we fall back to an ephemeral port and rely on mDNS
// discovery (parity with the macOS and Windows hosts).
const preferredPort = 50808

// One protocol message (a superset of all event fields we read). Unknown `t`
// values and unknown extra keys are ignored, so the vocabulary can grow without
// breaking this host (a v2 client never errors against us).
type msg struct {
	T    string `json:"t"`
	C    string `json:"c"`
	K    string `json:"k"`
	S    string `json:"s"`
	Del  int    `json:"del"`
	B    int    `json:"b"`
	Down bool   `json:"down"`
	Dx   int    `json:"dx"`
	Dy   int    `json:"dy"`
	D    int    `json:"d"`
	Mods int    `json:"mods"`
	U    string `json:"u"`
	Name string `json:"name"`
	V    int    `json:"v"`
	// Overlay (ovl.*) fields — parsed so a v2 client never errors; NO-OP host-side.
	M   string  `json:"m"`
	X   float64 `json:"x"`
	Y   float64 `json:"y"`
	P   string  `json:"p"`
	Rf  float64 `json:"rf"`
	Dim int     `json:"dim"`
	Col string  `json:"col"`
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

// appVersion is what -version prints and the log records; a release build
// sets it with -ldflags "-X main.appVersion=<version>".
var appVersion = "dev"

// injectBlocked is true while /dev/uinput is unreachable and the host is
// running anyway (a desktop launch, where exiting would just look like the app
// ignored the click). The tray shows it; the retry loop in main clears it.
var injectBlocked atomic.Bool

// appSupport is shown in the tray About item.
const appSupport = "support.remotype@custavia.com"

var (
	listenPort int
	hostName   string
	zcMu       sync.Mutex
	zcServer   *zeroconf.Server
)

func main() {
	listDevices := flag.Bool("devices", false, "list the paired phones and exit")
	forgetAll := flag.Bool("forget-all", false, "remove every paired phone and exit")
	layoutFlag := flag.String("layout", "", "xkb keyboard layout to type under, e.g. es or es(cat); default: what the desktop reports, else us")
	showVersion := flag.Bool("version", false, "print the version and exit")
	noTray := flag.Bool("no-tray", false, "do not show a tray icon even on a desktop (run headless)")
	forceTray := flag.Bool("tray", false, "always show a tray icon, even if no desktop session is detected")
	flag.Parse()
	if *showVersion {
		fmt.Println("Remotype Host for Linux", appVersion)
		return
	}
	initLog()
	logf("Remotype Host for Linux %s", appVersion)
	identity = loadIdentity()
	layoutInit(*layoutFlag)

	// Management without a tray: the paired-devices list lives in
	// ~/.config/remotype-host/devices.json, and these are the only two things
	// anyone needs to do to it by hand.
	if *listDevices {
		devs := identity.list()
		if len(devs) == 0 {
			fmt.Println("No paired phones.")
			return
		}
		for _, d := range devs {
			seen := "never"
			if d.LastSeen != nil {
				seen = d.LastSeen.Format(time.RFC3339)
			}
			fmt.Printf("%s  %s  paired %s  last seen %s\n", d.Name, d.Platform, d.PairedAt.Format("2006-01-02"), seen)
		}
		return
	}
	if *forgetAll {
		identity.forgetAll()
		fmt.Println("All paired phones removed. Each one will need to pair again.")
		return
	}

	// Before the socket opens: prove this build's RT1 agrees with the frozen
	// spec. A drift between the Go, Swift and Kotlin implementations shows up
	// in the field as "connects, then dies, on one platform only" — this turns
	// that into one line in the log.
	rt1SelfTest()

	// Bring up the uinput virtual devices before we advertise.
	wantTray := *forceTray || (!*noTray && hasDesktopSession())
	if err := injectInit(); err != nil {
		fmt.Println("Could not open /dev/uinput:", err)
		fmt.Println("Fix: add yourself to the 'input' group and install the udev rule (see README.md).")
		if !wantTray {
			// A terminal launch: the two lines above are on the user's screen
			// and exiting is the honest answer.
			os.Exit(1)
		}
		// A desktop launch has no console — an exit here looks like "I clicked
		// it and nothing happened", which was the whole first run. Stay up,
		// say why where the user can see it (tray + notification), and keep
		// re-trying: the udev-rule fix takes effect live, the group fix on the
		// next login, and either way the warning clears itself.
		logf("uinput unavailable (%v) — staying up, injection off until it appears", err)
		injectBlocked.Store(true)
		notifyDesktop("Remotype Host can’t type yet",
			"No access to /dev/uinput. Add yourself to the 'input' group and install the udev rule (see the README), then log out and back in.")
		go func() {
			for {
				time.Sleep(3 * time.Second)
				if injectInit() == nil {
					injectBlocked.Store(false)
					trayClearInjectWarning()
					logf("uinput became available — injection online")
					notifyDesktop("Remotype Host is ready", "Your phone can type on this computer now.")
					return
				}
			}
		}()
	}
	defer injectClose()

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", preferredPort))
	if err != nil {
		ln, err = net.Listen("tcp", ":0") // 50808 taken → ephemeral + mDNS
	}
	if err != nil {
		fmt.Println("Could not listen:", err)
		os.Exit(1)
	}
	listenPort = ln.Addr().(*net.TCPAddr).Port
	hostName, _ = os.Hostname()
	advertise()
	go advertiseWatchdog()
	defer func() {
		zcMu.Lock()
		if zcServer != nil {
			zcServer.Shutdown()
		}
		zcMu.Unlock()
	}()

	logf("Remotype Host running. Listening on port %d, advertising _hsbtk._tcp.", listenPort)

	// The accept loop runs on its own goroutine so the main goroutine can host
	// the tray UI (which owns the process's main loop, like the macOS menu bar
	// and the Windows tray).
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				continue
			}
			go handle(conn)
		}
	}()

	// On a desktop, show a tray icon and menu — the same shape as the macOS
	// menu bar and the Windows tray. On a headless machine (no display), stay a
	// plain background process and put the pairing code in the log. -tray and
	// -no-tray force the choice.
	if wantTray {
		runTray() // blocks on the tray event loop; sets pairing.onChange itself
		return
	}
	pairing.setOnChange(pairingConsoleStatus)
	fmt.Println("Open Remotype on your phone (same Wi-Fi) and pick this computer. A pairing code appears here the first time.")
	fmt.Println()
	select {} // headless: block forever; the accept loop runs above
}

// hasDesktopSession reports whether a graphical session is present, so the tray
// is shown on a desktop and skipped on a headless server.
func hasDesktopSession() bool {
	return os.Getenv("WAYLAND_DISPLAY") != "" || os.Getenv("DISPLAY") != ""
}

// advertise (re)registers the Bonjour service. The os TXT record lets the
// phone show a platform glyph in the host list before any connection exists.
func advertise() {
	zcMu.Lock()
	defer zcMu.Unlock()
	if zcServer != nil {
		zcServer.Shutdown()
		zcServer = nil
	}
	s, err := zeroconf.Register("Remotype Host ("+hostName+")", "_hsbtk._tcp", "local.", listenPort, []string{"os=linux"}, nil)
	if err != nil {
		logf("mDNS registration failed (the phone may not auto-discover): %v", err)
		return
	}
	zcServer = s
}

// advertiseWatchdog keeps the Bonjour registration alive for the life of the
// process. zeroconf.Register binds its multicast sockets to the interfaces
// that exist when it is called and never re-binds, so a Wi-Fi reconnect, a
// suspend/resume or a VPN interface coming up leaves it answering on sockets
// that no longer carry traffic. Three independent signals, because they fail
// differently: the address set changed, the clock jumped (suspend), or nothing
// happened for a long while (a socket that died quietly).
func advertiseWatchdog() {
	const tick = 15 * time.Second
	const backstop = 10 * time.Minute
	last := ifaceFingerprint()
	lastAdv := time.Now()
	for {
		before := time.Now()
		time.Sleep(tick)
		now := time.Now()
		slept := now.Sub(before) > 4*tick
		fp := ifaceFingerprint()
		switch {
		case fp != last:
			logf("network changed — re-advertising")
			last = fp
			advertise()
			lastAdv = now
		case slept:
			logf("woke from suspend — re-advertising")
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

// connState is per-connection: the reply writer, the negotiated protocol
// version, and this connection's trust state. Every field on rt1 is read or
// written under mu: the read goroutine advances the handshake and the receive
// counter, while send advances the send counter.
type connState struct {
	mu      sync.Mutex
	w       *bufio.Writer
	rt1     rt1State
	version int
}

// send writes one newline-delimited frame to the phone (thread-safe). Once the
// session is open the frame is a base64 sealed blob rather than JSON; the
// newline framing itself never changes.
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

// The RT1 helpers take mu for the shortest possible span: the read goroutine
// must NOT hold it across dispatch, which calls send.

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

	cs := &connState{w: bufio.NewWriter(conn)}
	logf("Phone connected: %s", conn.RemoteAddr())
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
				diagnoseOpenFailure(line)
				return
			}
			line = plain
		}
		var m msg
		if err := json.Unmarshal(line, &m); err != nil {
			continue // skip unparseable lines, keep the connection
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
	logf("Phone disconnected.")
}

// handleHandshake answers the only messages accepted before a connection is
// open. It returns true when the line was a handshake message and must go no
// further. `hello` deliberately returns false: it starts the session handshake,
// but dispatch already knows how to answer one, so the RT1 fields are handled
// there instead of duplicating the capability reply.
func handleHandshake(m msg, cs *connState) bool {
	switch m.T {
	case "pair.begin":
		// Show the code on EVERY pair.begin, not only when none is live: a
		// phone re-tapping the computer is exactly the moment the user is
		// looking for it. Then read the code AFTER showing — a transcript built
		// on an empty string can never match what the user types.
		showPairingWindow()
		code := pairing.live()
		cs.mu.Lock()
		reply := cs.rt1.beginPairing(m.Dev, m.SPK, m.EPK, m.Name, m.Plat, code, hostName)
		cs.mu.Unlock()
		cs.send(reply)
		return true

	case "pair.cancel":
		// The user tapped Cancel on the phone. Retire the code and say so
		// here: a code still on screen that nobody is typing reads as "still
		// waiting", when the truth is that the phone walked away.
		cs.mu.Lock()
		pairingHere := cs.rt1.isPairing()
		cs.rt1.cancelPairing()
		cs.mu.Unlock()
		if pairingHere {
			pairing.endedByPhone("Pairing was cancelled on the phone", "cancelled on the phone")
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
		// rt.ok is the host's LAST plaintext line (RT1 §3) — the phone is
		// still reading in the clear when it arrives.
		cs.sendPlaintext(reply)
		if opened {
			logf("RT1: session open with %s", name)
		}
		return true
	}
	return false
}

// dispatch routes one parsed message.
//
// THE GUARD is the first thing in it, and it is the reason RT1 exists: before
// it, every case below was reachable by anything that could open a TCP
// connection to this port. It sits above the switch because the messages that
// matter most — input — are the ones handled first.
func dispatch(m msg, cs *connState) {
	if !cs.rt1IsOpen() && m.T != "hello" && m.T != "ping" {
		// `hello` IS the start of the handshake. `ping` is pure liveness and
		// grants nothing — and dropping it would break pairing: the phone
		// pings every 5 s and its watchdog tears down a link that never pongs,
		// while the user is still reading the code off the screen.
		logf("RT1: dropped a message from an unauthenticated connection")
		return
	}
	switch m.T {
	case "ping":
		cs.send(map[string]any{"t": "pong"})
	case "hello":
		cs.version = m.V
		logf("Hello from %s", m.Name)
		hi := map[string]any{"t": "hi", "v": protocolVersion, "name": hostName, "os": "linux"}

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
			return
		}

		// No RT1 in the hello. Answer it anyway — an unanswered hello leaves
		// an older phone hanging on its timer — but the connection stays
		// UNAUTHENTICATED, so the guard drops everything that follows. `rt`
		// and `hid` ride along so an RT1-capable phone that simply has no
		// pairing yet can see what to do next.
		cs.mu.Lock()
		cs.rt1.markLegacy()
		cs.mu.Unlock()
		logf("RT1: %s connected without RT1 — refusing input until it pairs", m.Name)
		fmt.Printf("  %s connected with an app that predates pairing. Update the phone app; nothing will be typed until it pairs.\n", m.Name)
		hi["rt"] = rt1Version
		hi["hid"] = identity.hostID
		cs.send(hi)
		return
	case "mod":
		setModifierHeld(m.B, m.Down)
	case "key":
		if m.C != "" {
			typeChar(m.C, m.Mods)
		} else if m.K != "" {
			pressNamed(m.K, m.Mods)
		}
	case "text":
		for i := 0; i < m.Del; i++ {
			pressNamed("backspace", 0)
		}
		typeString(m.S)
	case "mm":
		moveMouse(m.Dx, m.Dy)
	case "mb":
		mouseButton(m.B, m.Down, m.Mods)
	case "mc":
		mouseButton(m.B, true, m.Mods)
		mouseButton(m.B, false, m.Mods)
	case "sc":
		scrollWheel(m.Dx, m.Dy)
	case "zoom":
		zoom(m.D)
	case "cc":
		consumer(m.U)
	case "ovl.mode", "ovl.move", "ovl.ink", "ovl.clear", "ovl.cursor":
		// The Spotlight overlay is a macOS/Windows feature for now. Parse and
		// no-op so a v2 client in Spotlight mode never errors against us.
	}
}

// diagnoseOpenFailure logs why a sealed line could not be opened, telling the
// two causes apart. It only ever prints locally (no distinguishable error goes
// on the wire — that would be a decryption oracle). A line that is valid JSON
// means the peer sent a PLAINTEXT frame while the host already considered the
// session open — a peer-side ordering bug, not bad keys. A line that
// base64-decodes to a blob GCM rejects means the keys or counter diverged.
func diagnoseOpenFailure(line []byte) {
	head := line
	if len(head) > 48 {
		head = head[:48]
	}
	looksJSON := len(line) > 0 && (line[0] == '{' || line[0] == '[')
	decoded, b64err := base64.StdEncoding.DecodeString(string(line))
	logf("RT1 DIAG: len=%d looksLikePlaintextJSON=%v validBase64=%v decodedLen=%d b64err=%v head=%q",
		len(line), looksJSON, b64err == nil, len(decoded), b64err, string(head))
}
