//go:build !linux

// The tray is Linux-only in this program; this stub lets the package build for
// type-checking on other systems (like inject_other.go). runTray is never
// reached off Linux — hasDesktopSession is the same everywhere, but a non-Linux
// build has no injector and exits before here.
package main

func runTray() {}

func trayClearInjectWarning() {}
