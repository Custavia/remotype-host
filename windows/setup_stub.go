//go:build !windows

// Non-Windows stub of the setup wizard (the real one is setup_windows.go).
package main

func showSetupWizard() { logf("setup wizard is Windows-only") }
