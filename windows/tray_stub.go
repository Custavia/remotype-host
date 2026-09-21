//go:build !windows

// Non-Windows stub of the tray UI (real one in tray_windows.go). The host only
// runs on Windows; this just lets the package cross-build on macOS/Linux. main()
// blocks here so it doesn't exit immediately during a stub build/run.
package main

func runTray() { select {} }

func trayLegacyPhone(name string) { logf("RT1: %s is too old to pair", name) }
