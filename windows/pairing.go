package main

import (
	"os"
	"sync"
	"time"
)

// The live pairing code, and the rules that keep a 60-bit secret a secret.
//
// One code at a time, ten-minute window, three attempts and it burns. The
// three-attempt rule is safe *only* because the code is 60 bits — a guess is
// 3/2^60. Shortening the code would not be a UX improvement; it would silently
// invalidate this rule and reintroduce the offline dictionary attack the design
// rejected. See docs/RT1.md §2.1.
type pairingCode struct {
	mu         sync.Mutex
	code       string
	expiresAt  time.Time
	attempts   int
	lastPaired string
	// status replaces the code on screen when the ceremony ended without a
	// pairing — the phone cancelled, or dropped — so the window says what
	// happened instead of showing a code that is no longer valid.
	status string
	// onChange lets the tray redraw without polling.
	onChange func()
}

const (
	pairingWindow      = 10 * time.Minute
	pairingMaxAttempts = 3
)

var pairing = &pairingCode{}

// show mints a fresh code. Calling it while one is live deliberately replaces
// it: the user asked for a new code, which is the documented way out of "I
// mistyped it twice and I am not sure how many tries I have left".
func (p *pairingCode) show() string {
	code, err := rt1GenerateCode()
	if err != nil {
		logf("RT1: could not generate a pairing code: %v", err)
		return ""
	}
	p.mu.Lock()
	p.code = code
	p.expiresAt = time.Now().Add(pairingWindow)
	p.attempts = 0
	p.lastPaired = ""
	p.status = ""
	p.mu.Unlock()
	logf("RT1: pairing code shown, valid for 10 minutes")
	writeTestCode(code)
	p.notify()
	return code
}

// live returns the usable code, or "" when none is. Reading does not consume.
func (p *pairingCode) live() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.code == "" || time.Now().After(p.expiresAt) {
		return ""
	}
	return p.code
}

func (p *pairingCode) secondsRemaining() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.code == "" {
		return 0
	}
	s := int(time.Until(p.expiresAt).Seconds())
	if s < 0 {
		return 0
	}
	return s
}

func (p *pairingCode) noteFailure() {
	p.mu.Lock()
	p.attempts++
	n := p.attempts
	burn := n >= pairingMaxAttempts
	if burn {
		p.code = ""
		p.attempts = 0
	}
	p.mu.Unlock()
	logf("RT1: pairing attempt failed (%d/%d)", n, pairingMaxAttempts)
	if burn {
		logf("RT1: pairing code retired — too many failed attempts")
		p.notify()
	}
}

func (p *pairingCode) noteSuccess(name string) {
	p.mu.Lock()
	p.code = ""
	p.attempts = 0
	p.lastPaired = name
	p.status = ""
	p.mu.Unlock()
	logf("RT1: pairing code retired — paired with %s", name)
	p.notify()
}

// retire drops a live code on purpose — the user closed the window before any
// phone finished with it. A code nobody is looking at must not stay valid for
// the rest of its ten minutes.
func (p *pairingCode) retire(why string) {
	p.mu.Lock()
	had := p.code != ""
	p.code = ""
	p.attempts = 0
	p.mu.Unlock()
	if had {
		logf("RT1: pairing code retired — %s", why)
		p.notify()
	}
}

// endedByPhone retires the code because the PHONE ended the ceremony — the user
// tapped Cancel (pair.cancel), or the connection that began pairing dropped
// before it finished. The window shows [msg] in place of the code: a code
// nobody is typing must not stay on screen looking valid.
func (p *pairingCode) endedByPhone(msg, why string) {
	p.mu.Lock()
	p.code = ""
	p.attempts = 0
	p.status = msg
	p.mu.Unlock()
	logf("RT1: pairing code retired — %s", why)
	p.notify()
}

// statusMessage is the text shown instead of a code, or "".
func (p *pairingCode) statusMessage() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.status
}

func (p *pairingCode) paired() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.lastPaired
}

// setOnChange is how the tray registers. It takes the mutex because the
// handshake goroutine reads onChange the moment a phone pairs, which can be
// before the tray has finished starting.
func (p *pairingCode) setOnChange(f func()) {
	p.mu.Lock()
	p.onChange = f
	p.mu.Unlock()
}

func (p *pairingCode) notify() {
	p.mu.Lock()
	f := p.onChange
	p.mu.Unlock()
	if f != nil {
		f()
	}
}

// writeTestCode is a TEST HOOK. When REMOTYPE_RT1_TEST_CODE_FILE names a path,
// the live code is written there as well as shown.
//
// It exists so the happy path of the ceremony can be driven by
// spec/rt1/interop_host.py against a real build. It takes an environment
// variable set before launch — not a flag, a preference or a tray item — so
// nothing a running host can be talked into doing turns it on, and anyone who
// can set this process's environment and read the file it names can already
// read identity.bin next to it.
func writeTestCode(code string) {
	path := os.Getenv("REMOTYPE_RT1_TEST_CODE_FILE")
	if path == "" {
		return
	}
	logf("RT1: TEST HOOK ACTIVE — writing the pairing code to %s", path)
	if err := os.WriteFile(path, []byte(code), 0o600); err != nil {
		logf("RT1: could not write the test code file: %v", err)
	}
}
