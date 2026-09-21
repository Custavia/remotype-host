//go:build !linux

// No-op injector stubs so the package compiles on non-Linux hosts (macOS,
// Windows, …). The real uinput implementation lives in inject_linux.go; this
// file exists only so `go build` succeeds off-Linux for type-checking/CI.
package main

import "errors"

// injectInit fails loudly off-Linux — there is no uinput device to open.
func injectInit() error {
	return errors.New("the Linux Remotype host only runs on Linux (uinput is Linux-only)")
}

func injectClose() {}

func typeChar(c string, mods int)            {}
func typeString(s string)                    {}
func pressNamed(name string, mods int)       {}
func setModifierHeld(bit int, down bool)     {}
func moveMouse(dx, dy int)                   {}
func mouseButton(b int, down bool, mods int) {}
func scrollWheel(dx, dy int)                 {}
func zoom(d int)                             {}
func consumer(u string)                      {}
func releaseAllModifiers()                   {}
