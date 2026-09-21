//go:build !windows

// Non-Windows stubs of the cast controller (real one in cast_windows.go).
// Discovery (discovery.go) is portable; only the Miracast capability gate,
// the Win+K session, and the power/topology plumbing are Windows-only. These
// no-ops let the package cross-build on macOS/Linux; the host only ever RUNS
// on Windows.
package main

func castInit()                      {}
func miracastAvailable() bool        { return false }
func castScanHook(active bool)       {}
func castStart(cs *connState, m msg) {}
func castStop(cs *connState, m msg)  {}
func castStateOnHello(cs *connState) {}
func castShutdown()                  {}
