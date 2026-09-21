//go:build !windows

// Non-Windows builds: MCM edge-flow host detection is a no-op (the real one is in
// edge_windows.go).
package main

func edgeArm(cs *connState, sides []string) {}
func edgeDisarm(cs *connState)               {}
func edgeEnter(cs *connState, from string, y float64) {}
func edgeRelease(cs *connState, to string, y float64) {}
