//go:build !windows

// Non-Windows stubs for the v2 control-event primitives (real versions in
// extras_windows.go). These let main.go compile on macOS/Linux for the
// cross-build / lint check; the host only ever RUNS on Windows.
package main

func getClipboardText() (string, bool, bool)  { return "", false, false }
func setClipboardText(s string) bool          { return false }
func cpuTimes() (idle, total uint64, ok bool) { return 0, 0, false }
func ramPercent() int                         { return 0 }
func volPercent() int                         { return -1 }
func openApp(name string) bool                { return false }
