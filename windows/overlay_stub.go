//go:build !windows

// Non-Windows stub of the Spotlight overlay controller. The overlay is a Win32
// layered-window feature (see overlay_windows.go); on macOS/Linux every method
// is a no-op so the package still compiles and `go vet` / cross-builds pass.

package main

// Overlay is the no-op controller on non-Windows targets.
type Overlay struct{}

func newOverlay() *Overlay { return &Overlay{} }

func (o *Overlay) SetMode(m string, rf float64, dim int, col string) {}
func (o *Overlay) Move(x, y float64)                                 {}
func (o *Overlay) SetTimer(on bool, secs int, warn bool)             {}
func (o *Overlay) Ink(phase string, x, y float64)                    {}
func (o *Overlay) Clear()                                            {}
func (o *Overlay) Reset()                                            {}
