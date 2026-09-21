//go:build linux

package main

// Inject a handful of specific keys so we can see what a chosen xkb layout
// makes of them. The point is the SEMICOLON key: on a US layout it is ";", on a
// Spanish one it is "ñ". We always send the same scancode — the layout decides.
import (
	"fmt"
	"os/exec"
	"time"
)

func main() {
	if err := injectInit(); err != nil {
		fmt.Println("init:", err)
		return
	}
	defer injectClose()
	time.Sleep(6000 * time.Millisecond) // device must exist BEFORE the observer starts
	exec.Command("true").Run()
	for _, s := range []string{";", "n", "'", "[", "z"} {
		typeChar(s, 0)
		time.Sleep(250 * time.Millisecond)
	}
	time.Sleep(500 * time.Millisecond)
}

const (
	modCtrl  = 1
	modShift = 2
	modAlt   = 4
	modGUI   = 8
)
