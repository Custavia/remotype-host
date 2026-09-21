package main

import (
	"fmt"
	"sync"
	"time"
)

// inputTelemetry samples realtime-input cadence + inject/overlay-render latency so
// we can diagnose jitter/sluggishness:
//   - gap stats = are events arriving SMOOTHLY from the phone (network + phone send
//     path). Big/irregular gaps ⇒ the send-side/network jitter the cast-discovery
//     gate targeted.
//   - inject stats = how long the HOST takes to inject a move (SendInput) or redraw
//     the Spotlight overlay (GDI). Big values ⇒ host-side CPU sluggishness.
// It logs one line per second while input flows, silent when idle.
type inputTelemetry struct {
	mu     sync.Mutex
	lastAt time.Time
	n      int     // realtime events this window
	gapSum float64 // sum of inter-arrival gaps (ms)
	gapMax float64
	inj    map[string]*injStat
}

type injStat struct {
	sum, max float64
	n        int
}

var inputTel = &inputTelemetry{inj: map[string]*injStat{}}

// realtime input opcodes whose arrival cadence matters for jitter.
var rtInputOps = map[string]bool{
	"mm": true, "sc": true, "ovl.move": true, "ovl.ink": true,
	"ovl.cursor": true, "tv.pan": true, "mb": true, "mc": true,
	"key": true, "mod": true, "cc": true, "zoom": true,
}

func (t *inputTelemetry) maybeArrival(op string) {
	if !rtInputOps[op] {
		return
	}
	now := time.Now()
	t.mu.Lock()
	if !t.lastAt.IsZero() {
		gap := float64(now.Sub(t.lastAt).Microseconds()) / 1000.0
		t.gapSum += gap
		if gap > t.gapMax {
			t.gapMax = gap
		}
		t.n++
	}
	t.lastAt = now
	t.mu.Unlock()
}

func (t *inputTelemetry) inject(kind string, d time.Duration) {
	ms := float64(d.Microseconds()) / 1000.0
	t.mu.Lock()
	s := t.inj[kind]
	if s == nil {
		s = &injStat{}
		t.inj[kind] = s
	}
	s.sum += ms
	if ms > s.max {
		s.max = ms
	}
	s.n++
	t.mu.Unlock()
}

func (t *inputTelemetry) runFlush() {
	tk := time.NewTicker(time.Second)
	defer tk.Stop()
	for range tk.C {
		t.mu.Lock()
		if t.n > 0 {
			detail := ""
			for k, s := range t.inj {
				if s.n > 0 {
					detail += fmt.Sprintf(" %s(avg=%.2f max=%.2f n=%d)", k, s.sum/float64(s.n), s.max, s.n)
				}
			}
			logf("JITTER n=%d/s gap avg=%.1fms max=%.1fms inject%s",
				t.n, t.gapSum/float64(t.n), t.gapMax, detail)
		}
		t.n, t.gapSum, t.gapMax = 0, 0, 0
		t.inj = map[string]*injStat{}
		t.mu.Unlock()
	}
}
