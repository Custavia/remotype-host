//go:build windows

// Host-side edge detection for MCM edge-flow (Flow/Synergy style). The phone arms
// the screen edges that lead to a neighbor computer; while armed, we poll the
// cursor and report when it hits an armed edge, so the phone can run its
// resistance overlay and commit a switch. On commit the phone parks this host
// (edge.release) and warps the cursor onto the next host (edge.enter).
//
// Polling runs ONLY while armed (fixes the reverted always-on 20Hz leak) and is
// torn down per-connection. Cursor warp reuses SetCursorPos (inject_windows.go);
// screen metrics + cursor read reuse tv_windows.go.
package main

import (
	"runtime"
	"sync"
	"time"
)

type edgeSession struct {
	cs    *connState
	stop  chan struct{}
	mu    sync.Mutex
	sides map[string]bool
}

var (
	edgeMu       sync.Mutex
	edgeSessions = map[*connState]*edgeSession{}
)

// edgeArm starts (or updates) edge polling for the given sides.
func edgeArm(cs *connState, sides []string) {
	if len(sides) == 0 {
		edgeDisarm(cs)
		return
	}
	edgeMu.Lock()
	s := edgeSessions[cs]
	if s == nil {
		s = &edgeSession{cs: cs, stop: make(chan struct{}), sides: map[string]bool{}}
		edgeSessions[cs] = s
		go s.loop()
	}
	edgeMu.Unlock()
	set := map[string]bool{}
	for _, x := range sides {
		set[x] = true
	}
	s.mu.Lock()
	s.sides = set
	s.mu.Unlock()
}

func edgeDisarm(cs *connState) {
	edgeMu.Lock()
	s := edgeSessions[cs]
	delete(edgeSessions, cs)
	edgeMu.Unlock()
	if s != nil {
		close(s.stop)
	}
}

// edgeEnter warps the cursor onto the `from` edge at normalized y — the cursor
// "arrives" on this computer when the phone flows focus in.
func edgeEnter(cs *connState, from string, y float64) {
	sw, sh := primaryScreenSize()
	x, yy := edgeCoord(from, y, sw, sh)
	procSetCursorPos.Call(uintptr(x), uintptr(yy))
}

// edgeRelease parks the cursor a hair inside the `to` edge (so a re-arm won't
// instantly re-fire) and stops polling; the phone re-arms on return.
func edgeRelease(cs *connState, to string, y float64) {
	sw, sh := primaryScreenSize()
	x, yy := edgeCoord(to, y, sw, sh)
	switch to {
	case "left":
		x += 4
	case "right":
		x -= 4
	case "top":
		yy += 4
	case "bottom":
		yy -= 4
	}
	procSetCursorPos.Call(uintptr(x), uintptr(yy))
	edgeDisarm(cs)
}

func edgeCoord(side string, y float64, sw, sh int) (int, int) {
	switch side {
	case "left":
		return 0, int(y * float64(sh))
	case "right":
		return sw - 1, int(y * float64(sh))
	case "top":
		return int(y * float64(sw)), 0
	case "bottom":
		return int(y * float64(sw)), sh - 1
	}
	return sw / 2, sh / 2
}

func (s *edgeSession) loop() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	t := time.NewTicker(16 * time.Millisecond) // ~60Hz, ONLY while armed
	defer t.Stop()
	last := ""
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			px, py := cursorPixels()
			sw, sh := primaryScreenSize()
			s.mu.Lock()
			sides := s.sides
			s.mu.Unlock()
			hit := ""
			switch {
			case sides["left"] && px <= 0:
				hit = "left"
			case sides["right"] && px >= sw-1:
				hit = "right"
			case sides["top"] && py <= 0:
				hit = "top"
			case sides["bottom"] && py >= sh-1:
				hit = "bottom"
			}
			if hit != "" && hit != last {
				last = hit
				var yn float64
				if hit == "left" || hit == "right" {
					yn = float64(py) / float64(sh)
				} else {
					yn = float64(px) / float64(sw)
				}
				s.cs.send(map[string]any{"t": "edge", "side": hit, "y": yn})
			} else if hit == "" && last != "" {
				last = ""
				s.cs.send(map[string]any{"t": "edge.cancel"})
			}
		}
	}
}
