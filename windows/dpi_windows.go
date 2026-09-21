//go:build windows

package main

import (
	"golang.org/x/sys/windows"
)

// Declare PER-MONITOR-AWARE-V2 before anything queries a screen size or makes a
// window. Without this the process is DPI-*unaware*, and Windows silently lies
// to it: on a 2736x1824 panel at 150% scaling, GetSystemMetrics reports
// 1824x1216 and every window we create is rendered at that size and then
// bitmap-STRETCHED by the compositor.
//
// That one defect cost us three visible things on Windows that macOS never had:
//   - TV mode captured the 1824x1216 virtualised desktop, so the phone got a
//     1.5x-downscaled screen and the "1:1 native" detent was a lie — text
//     looked soft no matter what quality we sent.
//   - The spotlight/annotate overlay was rasterised at 1824x1216 and stretched,
//     so every edge in it was blurry.
//   - Cursor mapping ran on the virtual grid, so normalized positions landed
//     off-target on a scaled display.
//
// init() (not main) so it lands before ANY of the other files can touch a DC:
// awareness is per-process and can only be set before the first window/DC.
func init() {
	user32 := windows.NewLazySystemDLL("user32.dll")

	// Windows 10 1703+. The V2 context is the one that also gives us
	// per-monitor DPI change messages and correctly-scaled non-client area.
	const perMonitorAwareV2 = ^uintptr(3) // (DPI_AWARENESS_CONTEXT)-4
	if p := user32.NewProc("SetProcessDpiAwarenessContext"); p.Find() == nil {
		if ret, _, _ := p.Call(perMonitorAwareV2); ret != 0 {
			return
		}
	}
	// Windows 8.1 fallback: 2 = PROCESS_PER_MONITOR_DPI_AWARE.
	shcore := windows.NewLazySystemDLL("shcore.dll")
	if p := shcore.NewProc("SetProcessDpiAwareness"); p.Find() == nil {
		if ret, _, _ := p.Call(2); ret == 0 {
			return
		}
	}
	// Vista+ last resort: system-DPI aware. Still far better than virtualised.
	if p := user32.NewProc("SetProcessDPIAware"); p.Find() == nil {
		p.Call()
	}
}
