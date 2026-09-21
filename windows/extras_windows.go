//go:build windows

// Win32 primitives for the v2 control events: clipboard bridge, the vitals
// stream (CPU/RAM), and open-app. The protocol/dispatch logic lives in main.go;
// this file is only the thin platform layer (stubs in extras_stub.go let the
// package cross-build on macOS/Linux). See PROTOCOL.md.
package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")
	shell32  = windows.NewLazySystemDLL("shell32.dll")

	// user32 is declared in inject_windows.go (same package + build tag).
	procOpenClipboard              = user32.NewProc("OpenClipboard")
	procCloseClipboard             = user32.NewProc("CloseClipboard")
	procEmptyClipboard             = user32.NewProc("EmptyClipboard")
	procGetClipboardData           = user32.NewProc("GetClipboardData")
	procSetClipboardData           = user32.NewProc("SetClipboardData")
	procIsClipboardFormatAvailable = user32.NewProc("IsClipboardFormatAvailable")

	procGlobalAlloc          = kernel32.NewProc("GlobalAlloc")
	procGlobalFree           = kernel32.NewProc("GlobalFree")
	procGlobalLock           = kernel32.NewProc("GlobalLock")
	procGlobalUnlock         = kernel32.NewProc("GlobalUnlock")
	procGlobalSize           = kernel32.NewProc("GlobalSize")
	procGetSystemTimes       = kernel32.NewProc("GetSystemTimes")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
	// Cast power assertion (cast_windows.go, docs/CASTING.md §10.4).
	procSetThreadExecutionState = kernel32.NewProc("SetThreadExecutionState")

	procShellExecuteW = shell32.NewProc("ShellExecuteW")
)

const (
	cfUnicodeText = 13
	gmemMoveable  = 0x0002
	swShowNormal  = 1
	// Hard ceiling for a single clipboard read so a pathological multi-MB
	// clipboard isn't scanned to its null terminator before we reject it.
	clipReadCeilBytes = 4 * 1024 * 1024
)

// --- Clipboard -------------------------------------------------------------

// getClipboardText returns the host clipboard's Unicode text. ok=false means no
// text format is present ("empty"); tooLarge=true means it exceeds clipMaxBytes.
func getClipboardText() (text string, ok bool, tooLarge bool) {
	if r, _, _ := procIsClipboardFormatAvailable.Call(cfUnicodeText); r == 0 {
		return "", false, false
	}
	if r, _, _ := procOpenClipboard.Call(0); r == 0 {
		return "", false, false
	}
	defer procCloseClipboard.Call()

	h, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return "", false, false
	}
	// Quick reject before we read: GlobalSize is in bytes (UTF-16, +null).
	if sz, _, _ := procGlobalSize.Call(h); sz > clipReadCeilBytes {
		return "", false, true
	}
	ptr, _, _ := procGlobalLock.Call(h)
	if ptr == 0 {
		return "", false, false
	}
	defer procGlobalUnlock.Call(h)

	s := windows.UTF16PtrToString((*uint16)(unsafe.Pointer(ptr)))
	if len(s) > clipMaxBytes { // len(string) = UTF-8 byte length
		return "", false, true
	}
	return s, true, false
}

// setClipboardText replaces the host clipboard with s (UTF-16). Returns false on
// any Win32 failure.
func setClipboardText(s string) bool {
	u16, err := windows.UTF16FromString(s) // includes the null terminator
	if err != nil {
		return false
	}
	if r, _, _ := procOpenClipboard.Call(0); r == 0 {
		return false
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call()

	sz := uintptr(len(u16) * 2)
	h, _, _ := procGlobalAlloc.Call(gmemMoveable, sz)
	if h == 0 {
		return false
	}
	ptr, _, _ := procGlobalLock.Call(h)
	if ptr == 0 {
		procGlobalFree.Call(h)
		return false
	}
	dst := unsafe.Slice((*uint16)(unsafe.Pointer(ptr)), len(u16))
	copy(dst, u16)
	procGlobalUnlock.Call(h)

	if r, _, _ := procSetClipboardData.Call(cfUnicodeText, h); r == 0 {
		// On failure we still own the block — free it. On success the system
		// owns it and we must NOT free.
		procGlobalFree.Call(h)
		return false
	}
	return true
}

// --- Vitals ----------------------------------------------------------------

type fileTime struct{ low, high uint32 }

func ftU64(ft fileTime) uint64 { return uint64(ft.high)<<32 | uint64(ft.low) }

// cpuTimes returns cumulative idle + total CPU tick counts (kernel time already
// INCLUDES idle on Windows, so total = kernel + user). main.go diffs successive
// samples into a percentage. ok=false if GetSystemTimes failed.
func cpuTimes() (idle, total uint64, ok bool) {
	var fi, fk, fu fileTime
	r, _, _ := procGetSystemTimes.Call(
		uintptr(unsafe.Pointer(&fi)),
		uintptr(unsafe.Pointer(&fk)),
		uintptr(unsafe.Pointer(&fu)))
	if r == 0 {
		return 0, 0, false
	}
	return ftU64(fi), ftU64(fk) + ftU64(fu), true
}

type memoryStatusEx struct {
	length               uint32
	memoryLoad           uint32
	totalPhys            uint64
	availPhys            uint64
	totalPageFile        uint64
	availPageFile        uint64
	totalVirtual         uint64
	availVirtual         uint64
	availExtendedVirtual uint64
}

// ramPercent is the system memory load 0..100 (GlobalMemoryStatusEx).
func ramPercent() int {
	var m memoryStatusEx
	m.length = uint32(unsafe.Sizeof(m))
	if r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&m))); r == 0 {
		return 0
	}
	return int(m.memoryLoad)
}

// --- Open app --------------------------------------------------------------

// openApp launches an app by name via ShellExecuteW("open") — resolves through
// the App Paths registry + file associations (no shell, no string interpolation,
// matching the Mac host's Launch Services semantics). Returns false if the shell
// couldn't open it (HINSTANCE <= 32).
func openApp(name string) bool {
	verb, _ := windows.UTF16PtrFromString("open")
	file, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return false
	}
	r, _, _ := procShellExecuteW.Call(
		0, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(file)), 0, 0, swShowNormal)
	return r > 32
}
