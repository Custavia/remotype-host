//go:build !windows

// Non-Windows builds (dev/cross-compile on macOS) can't GDI-capture the screen,
// so TV mode is unsupported: tvSupported() is false (the hi handshake omits the
// `tv` flag, so phones hide TV mode) and the control entry points are no-ops.
package main

func tvSupported() bool                                            { return false }
func tvStart(cs *connState, w, h int, zoom float64, follow string) {}
func tvStop(cs *connState)                                         {}
func tvSetFollow(cs *connState, mode string)                       {}
func tvSetZoom(cs *connState, z float64)                           {}
func tvPan(cs *connState, dx, dy float64)                          {}
func tvPoint(cs *connState, u, v float64, seq int)                 {}
