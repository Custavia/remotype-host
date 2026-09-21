//go:build !windows

// Non-Windows stub of the input-injection layer. The real injector
// (inject_windows.go) uses Win32 SendInput / SetCursorPos and only exists on
// Windows; these no-ops let the package cross-build and `go build` on
// macOS/Linux (e.g. CI lint, the stub-compile check) without dragging in any
// platform code. The host binary is only ever RUN on Windows.

package main

func setModifierHeld(bit int, down bool)     {}
func typeChar(c string, mods int)            {}
func pressNamed(name string, mods int)       {}
func typeString(s string)                    {}
func moveMouse(dx, dy int)                   {}
func moveCursorNormalized(nx, ny float64)    {}
func mouseButton(b int, down bool, mods int) {}
func scrollWheel(dx, dy int)                 {}
func zoom(d int)                             {}
func consumer(u string)                      {}
func releaseAllModifiers()                   {}
