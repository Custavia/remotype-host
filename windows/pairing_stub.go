//go:build !windows

// Non-Windows stub of the pairing window (the real one is in
// pairing_windows.go). The host only ships on Windows; this lets the package
// build and RUN on macOS/Linux, which is what makes it testable by
// spec/rt1/interop_host.py without a Windows box.
//
// It mints the code exactly as the real window does — that part is not UI, and
// leaving it out made the ceremony unreachable off Windows. What it cannot do
// is show it, so the code goes to the log instead.
package main

func showPairingWindow() {
	code := pairing.live()
	if code == "" {
		code = pairing.show()
	}
	logf("RT1: pairing code is %s (no window on this platform)", code)
}
