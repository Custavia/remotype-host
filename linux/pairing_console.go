package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// The pairing "window" on Linux is the terminal the host runs in, plus a
// desktop notification when one is available. There is no tray yet, so the
// code has to reach the user through whatever surface exists: a host started
// from a shell shows it there, a host started as a service reaches the desktop
// through notify-send, and both are logged.
//
// showPairingWindow is idempotent: a live code is shown again, not replaced —
// the phone re-sends pair.begin when the user taps the computer a second time,
// which is exactly when they are looking for the code, not for a new one.
func showPairingWindow() {
	code := pairing.live()
	if code == "" {
		code = pairing.show()
	}
	if code == "" {
		return
	}
	printCode(code)
	notifyDesktop("Remotype pairing code", code+"\nEnter this on your phone within 10 minutes.")
}

// printCode draws the code so it can be read from across a room, which is
// where the phone usually is. Written to stdout directly rather than the log:
// a timestamped, line-wrapped code is one that gets typed wrong.
func printCode(code string) {
	line := strings.Repeat("─", len(code)+8)
	fmt.Fprintf(os.Stdout, "\n  ┌%s┐\n  │    %s    │   Pairing code — enter it on your phone\n  └%s┘   (valid for %d minutes)\n\n",
		line, code, line, int(pairingWindow/time.Minute))
}

// notifyDesktop posts a desktop notification through notify-send when it is
// installed; a host without a desktop, or without libnotify, simply relies on
// the terminal. Best effort, never blocking: the ceremony must not wait on a
// notification daemon.
func notifyDesktop(summary, body string) {
	path, err := exec.LookPath("notify-send")
	if err != nil {
		return
	}
	cmd := exec.Command(path, "--app-name=Remotype Host", "--expire-time=600000", summary, body)
	if err := cmd.Start(); err == nil {
		go func() { _ = cmd.Wait() }()
	}
}

// pairingConsoleStatus mirrors what the Windows pairing window paints in
// place of the code once a ceremony ends: paired, cancelled, or burned. Without
// it a terminal keeps showing a code that is no longer valid.
func pairingConsoleStatus() {
	if name := pairing.paired(); name != "" {
		fmt.Fprintf(os.Stdout, "\n  ✓ Paired with %s. The pairing code is no longer valid.\n\n", name)
		notifyDesktop("Remotype", "Paired with "+name)
		return
	}
	if msg := pairing.statusMessage(); msg != "" {
		fmt.Fprintf(os.Stdout, "\n  %s — the pairing code is no longer valid.\n\n", msg)
		return
	}
	if pairing.live() == "" {
		fmt.Fprintf(os.Stdout, "\n  The pairing code is no longer valid. Tap this computer on the phone for a new one.\n\n")
	}
}
