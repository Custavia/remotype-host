package main

import "sync"

// What the setup wizard knows.
//
// Windows has no equivalent of macOS's TCC queries: there is no call that
// answers "is this program blocked by the firewall". `netsh` prints its rules in
// the user's language, and the COM policy API is a long way from here for one
// boolean. So the wizard verifies the thing the user actually cares about
// instead of the thing that is easy to ask — a phone got through.
//
// That turns out to be the better check anyway. A host can have perfect firewall
// rules and still be unreachable (wrong network, VPN, AP isolation), and every
// one of those failures looks identical from the tray.
var setupState struct {
	mu           sync.Mutex
	phoneReached bool   // a TCP connection arrived from somewhere
	phoneName    string // …and it introduced itself
	sessionOpen  bool   // …and completed the RT1 handshake
	sessionName  string
	onChange     func()
}

func setupNotePhoneReached() {
	setupState.mu.Lock()
	first := !setupState.phoneReached
	setupState.phoneReached = true
	f := setupState.onChange
	setupState.mu.Unlock()
	if first {
		// The moment that retires the setup wizard for good — see needsSetup.
		markSetupDone()
		if f != nil {
			f()
		}
	}
}

func setupNotePhoneNamed(name string) {
	if name == "" {
		return
	}
	setupState.mu.Lock()
	changed := setupState.phoneName != name
	setupState.phoneName = name
	f := setupState.onChange
	setupState.mu.Unlock()
	if changed && f != nil {
		f()
	}
}

// hostSessionOpen records that a phone has completed the RT1 handshake — the
// only state that honestly means "connected". Pairing succeeding is a moment
// earlier and is not the same thing: the ceremony can finish and the session
// that follows on the same socket can still fail.
func hostNoteSessionOpen(name string) {
	setupState.mu.Lock()
	setupState.sessionOpen = true
	setupState.sessionName = name
	f := setupState.onChange
	setupState.mu.Unlock()
	if f != nil {
		f()
	}
}

func hostNoteSessionClosed() {
	setupState.mu.Lock()
	changed := setupState.sessionOpen
	setupState.sessionOpen = false
	setupState.sessionName = ""
	f := setupState.onChange
	setupState.mu.Unlock()
	if changed && f != nil {
		f()
	}
}

func hostSessionOpen() (bool, string) {
	setupState.mu.Lock()
	defer setupState.mu.Unlock()
	return setupState.sessionOpen, setupState.sessionName
}

func setupPhoneReached() (bool, string) {
	setupState.mu.Lock()
	defer setupState.mu.Unlock()
	return setupState.phoneReached, setupState.phoneName
}

func setupOnChange(f func()) {
	setupState.mu.Lock()
	setupState.onChange = f
	setupState.mu.Unlock()
}
