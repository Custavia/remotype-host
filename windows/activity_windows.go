//go:build windows

// Activity console — the tray's "Show activity" window.
//
// The host normally has ZERO visual presence (built -H windowsgui, tray only).
// This file gives the tray an on-demand console: AllocConsole + a branded
// banner, then a live feed of session activity (connected, disconnected, mode
// switches, TV/cast toggles). All the signals already flow through logf — this
// just surfaces them when, and only when, the user asks.
package main

import (
	"fmt"
	"os"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

var (
	activityMu   sync.Mutex
	activityOn   bool
	activityRing []string // last activityCap lines, replayed when the console opens
	conOut       *os.File
)

const activityCap = 200

const activityBanner = `
  ██████╗ ███████╗███╗   ███╗ ██████╗ ████████╗██╗   ██╗██████╗ ███████╗
  ██╔══██╗██╔════╝████╗ ████║██╔═══██╗╚══██╔══╝╚██╗ ██╔╝██╔══██╗██╔════╝
  ██████╔╝█████╗  ██╔████╔██║██║   ██║   ██║    ╚████╔╝ ██████╔╝█████╗
  ██╔══██╗██╔══╝  ██║╚██╔╝██║██║   ██║   ██║     ╚██╔╝  ██╔═══╝ ██╔══╝
  ██║  ██║███████╗██║ ╚═╝ ██║╚██████╔╝   ██║      ██║   ██║     ███████╗
  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝      ╚═╝   ╚═╝     ╚══════╝
                                                — by Custavia

  Live activity. Closing this window does not stop the host
  (hide it again from the tray: "Hide activity").
`

var (
	// kernel32 is declared in extras_windows.go — reuse it.
	procAllocCon    = kernel32.NewProc("AllocConsole")
	procFreeCon     = kernel32.NewProc("FreeConsole")
	procSetConTitle = kernel32.NewProc("SetConsoleTitleW")
)

// activityLog records a line and mirrors it to the console when open. Called
// from logf, so every existing signal (connect, disconnect, mode, TV, cast)
// arrives here with zero new call sites.
func activityLog(line string) {
	line = time.Now().Format("15:04:05") + "  " + line
	activityMu.Lock()
	defer activityMu.Unlock()
	activityRing = append(activityRing, line)
	if len(activityRing) > activityCap {
		activityRing = activityRing[len(activityRing)-activityCap:]
	}
	if activityOn && conOut != nil {
		fmt.Fprintln(conOut, line)
	}
}

// showActivity opens the branded console and replays recent history.
func showActivity() {
	activityMu.Lock()
	defer activityMu.Unlock()
	if activityOn {
		return
	}
	r, _, _ := procAllocCon.Call()
	if r == 0 { // already had a console (dev build) — just mark on
		conOut = os.Stdout
	} else {
		f, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0)
		if err != nil {
			procFreeCon.Call()
			return
		}
		conOut = f
	}
	title, _ := syscall.UTF16PtrFromString("Remotype — by Custavia · activity")
	procSetConTitle.Call(uintptr(unsafe.Pointer(title)))
	fmt.Fprint(conOut, activityBanner)
	for _, l := range activityRing {
		fmt.Fprintln(conOut, l)
	}
	activityOn = true
}

// hideActivity detaches the console again (tray item toggles back).
func hideActivity() {
	activityMu.Lock()
	defer activityMu.Unlock()
	if !activityOn {
		return
	}
	if conOut != nil && conOut != os.Stdout {
		conOut.Close()
	}
	conOut = nil
	procFreeCon.Call()
	activityOn = false
}

func activityVisible() bool {
	activityMu.Lock()
	defer activityMu.Unlock()
	return activityOn
}
