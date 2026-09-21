//go:build windows

// Display brightness for the Windows host (media `brightup`/`brightdown`) — parity
// with the macOS host's NX brightness keys. Two mechanisms, because they cover
// different displays:
//   - WMI (WmiMonitorBrightnessMethods.WmiSetBrightness) drives the INTERNAL /
//     laptop panel — the common brightness-key case. Invoked via a hidden
//     PowerShell one-shot (no COM, no new deps); validated on real hardware.
//   - DDC/CI (dxva2.dll) drives EXTERNAL monitors that speak it.
// Both are best-effort: a display that doesn't support one path just no-ops there.
//
// Brightness runs on its own worker goroutine (a PowerShell spawn is ~300ms) so it
// NEVER blocks the input-dispatch loop, and presses coalesce (a full queue drops
// extra steps) so mashing the key can't pile up processes.
package main

import (
	"context"
	"fmt"
	"os/exec"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	dxva2 = windows.NewLazySystemDLL("dxva2.dll")

	procGetNumberOfPhysicalMonitors = dxva2.NewProc("GetNumberOfPhysicalMonitorsFromHMONITOR")
	procGetPhysicalMonitors         = dxva2.NewProc("GetPhysicalMonitorsFromHMONITOR")
	procGetMonitorBrightness        = dxva2.NewProc("GetMonitorBrightness")
	procSetMonitorBrightness        = dxva2.NewProc("SetMonitorBrightness")
	procDestroyPhysicalMonitors     = dxva2.NewProc("DestroyPhysicalMonitors")

	// user32o (user32.dll) is declared in overlay_windows.go.
	procMonitorFromPoint = user32o.NewProc("MonitorFromPoint")
)

const (
	monitorDefaultToPrimary = 1
	brightnessStep          = 8 // percent per key press
)

// brightnessCh serializes brightness work off the dispatch goroutine; a small
// buffer coalesces a burst of key presses (extra steps are dropped, not queued).
var brightnessCh = make(chan int, 4)

func init() { go brightnessWorker() }

func brightnessWorker() {
	for delta := range brightnessCh {
		setBrightnessWMI(delta)  // internal / laptop panel
		setBrightnessDDC(delta)  // external DDC/CI monitors
	}
}

// adjustBrightness enqueues a brightness nudge (never blocks the caller).
func adjustBrightness(delta int) {
	select {
	case brightnessCh <- delta:
	default: // worker busy — drop this step rather than pile up PowerShell spawns
	}
}

// setBrightnessWMI reads the internal panel's current brightness, steps it by
// delta (clamped 0-100), and applies it via WMI. Runs a hidden PowerShell so a
// windowsgui host shows no console flash. Best-effort: no WMI panel ⇒ it errors
// and we ignore it.
func setBrightnessWMI(delta int) {
	ps := fmt.Sprintf(
		`$c=(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -EA Stop).CurrentBrightness;`+
			`$n=[Math]::Max(0,[Math]::Min(100,[int]$c+(%d)));`+
			`(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods)`+
			`|Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{Timeout=1;Brightness=[byte]$n}|Out-Null`,
		delta)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", ps)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	_ = cmd.Run()
}

// PHYSICAL_MONITOR: a monitor handle + a fixed 128-WCHAR description buffer.
type physicalMonitor struct {
	handle uintptr
	desc   [128]uint16
}

// setBrightnessDDC nudges every DDC/CI-capable EXTERNAL monitor on the primary
// display by delta percent, clamped to each monitor's own min/max. Best-effort:
// laptop panels (no DDC/CI) are silently skipped.
func setBrightnessDDC(delta int) {
	hmon, _, _ := procMonitorFromPoint.Call(0, uintptr(monitorDefaultToPrimary))
	if hmon == 0 {
		return
	}
	var count uint32
	if r, _, _ := procGetNumberOfPhysicalMonitors.Call(hmon, uintptr(unsafe.Pointer(&count))); r == 0 || count == 0 {
		return
	}
	mons := make([]physicalMonitor, count)
	if r, _, _ := procGetPhysicalMonitors.Call(hmon, uintptr(count), uintptr(unsafe.Pointer(&mons[0]))); r == 0 {
		return
	}
	defer procDestroyPhysicalMonitors.Call(uintptr(count), uintptr(unsafe.Pointer(&mons[0])))

	for i := range mons {
		var lo, cur, hi uint32
		if r, _, _ := procGetMonitorBrightness.Call(
			mons[i].handle,
			uintptr(unsafe.Pointer(&lo)), uintptr(unsafe.Pointer(&cur)), uintptr(unsafe.Pointer(&hi)),
		); r == 0 {
			continue // no DDC/CI brightness on this monitor — skip
		}
		next := int(cur) + delta
		if next < int(lo) {
			next = int(lo)
		}
		if next > int(hi) {
			next = int(hi)
		}
		procSetMonitorBrightness.Call(mons[i].handle, uintptr(uint32(next)))
	}
}
