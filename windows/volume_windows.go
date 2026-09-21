//go:build windows

// Master output volume for the vitals stream, via WASAPI's IAudioEndpointVolume.
//
// This used to return -1 ("unreadable"), which the phone renders by omitting the
// volume readout entirely — so the About-this-computer tile showed a volume on
// macOS and nothing on Windows. Same tile, same stream, missing number.
package main

import (
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	ole32               = windows.NewLazySystemDLL("ole32.dll")
	procCoInitializeEx  = ole32.NewProc("CoInitializeEx")
	procCoUninitialize  = ole32.NewProc("CoUninitialize")
	procCoCreateInstance = ole32.NewProc("CoCreateInstance")
)

// {BCDE0395-E52F-467C-8E3D-C4579291692E} CLSID_MMDeviceEnumerator
var clsidMMDeviceEnumerator = windows.GUID{
	Data1: 0xBCDE0395, Data2: 0xE52F, Data3: 0x467C,
	Data4: [8]byte{0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E},
}

// {A95664D2-9614-4F35-A746-DE8DB63617E6} IID_IMMDeviceEnumerator
var iidIMMDeviceEnumerator = windows.GUID{
	Data1: 0xA95664D2, Data2: 0x9614, Data3: 0x4F35,
	Data4: [8]byte{0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6},
}

// {5CDF2C82-841E-4546-9722-0CF74078229A} IID_IAudioEndpointVolume
var iidIAudioEndpointVolume = windows.GUID{
	Data1: 0x5CDF2C82, Data2: 0x841E, Data3: 0x4546,
	Data4: [8]byte{0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A},
}

const (
	coinitApartmentThreaded = 0x2
	clsctxAll               = 0x17
	eRender                 = 0
	eConsole                = 0

	// IUnknown
	vtRelease = 2
	// IMMDeviceEnumerator: ..., GetDefaultAudioEndpoint is slot 4
	vtGetDefaultAudioEndpoint = 4
	// IMMDevice: ..., Activate is slot 3
	vtActivate = 3
	// IAudioEndpointVolume: ..., GetMasterVolumeLevelScalar is slot 9
	vtGetMasterVolumeLevelScalar = 9
	// ..., GetMute is slot 15
	vtGetMute = 15
)

// call invokes the `slot`th entry of a COM object's vtable.
func call(obj uintptr, slot int, args ...uintptr) uintptr {
	vtbl := *(**[32]uintptr)(unsafe.Pointer(obj))
	fn := vtbl[slot]
	all := append([]uintptr{obj}, args...)
	var r uintptr
	switch len(all) {
	case 1:
		r, _, _ = syscall.SyscallN(fn, all[0])
	case 2:
		r, _, _ = syscall.SyscallN(fn, all[0], all[1])
	case 3:
		r, _, _ = syscall.SyscallN(fn, all[0], all[1], all[2])
	case 4:
		r, _, _ = syscall.SyscallN(fn, all[0], all[1], all[2], all[3])
	case 5:
		r, _, _ = syscall.SyscallN(fn, all[0], all[1], all[2], all[3], all[4])
	default:
		r, _, _ = syscall.SyscallN(fn, all...)
	}
	return r
}

func release(obj uintptr) {
	if obj != 0 {
		call(obj, vtRelease)
	}
}

// volPercent returns the default render endpoint's master volume as 0..100, or
// -1 when it cannot be read (no output device, or any COM step failing). A muted
// endpoint reads 0 — matching what the user sees on the Windows volume flyout,
// rather than the pre-mute level the scalar still holds.
//
// COM apartment state is per-THREAD, so the goroutine is pinned for the whole
// call; without that a scheduler migration mid-call would use an uninitialised
// thread and every reading after the first would fail.
func volPercent() int {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	hr, _, _ := procCoInitializeEx.Call(0, coinitApartmentThreaded)
	// S_OK (0) and S_FALSE (1) both mean "initialised"; only S_FALSE means it
	// was already initialised on this thread, and both require a matching
	// CoUninitialize.
	if int32(hr) < 0 {
		return -1
	}
	defer procCoUninitialize.Call()

	var enumerator uintptr
	r, _, _ := procCoCreateInstance.Call(
		uintptr(unsafe.Pointer(&clsidMMDeviceEnumerator)), 0, clsctxAll,
		uintptr(unsafe.Pointer(&iidIMMDeviceEnumerator)),
		uintptr(unsafe.Pointer(&enumerator)),
	)
	if int32(r) < 0 || enumerator == 0 {
		return -1
	}
	defer release(enumerator)

	var device uintptr
	if int32(call(enumerator, vtGetDefaultAudioEndpoint,
		eRender, eConsole, uintptr(unsafe.Pointer(&device)))) < 0 || device == 0 {
		return -1 // no output device at all — the phone omits the readout
	}
	defer release(device)

	var endpointVol uintptr
	if int32(call(device, vtActivate,
		uintptr(unsafe.Pointer(&iidIAudioEndpointVolume)), clsctxAll, 0,
		uintptr(unsafe.Pointer(&endpointVol)))) < 0 || endpointVol == 0 {
		return -1
	}
	defer release(endpointVol)

	var muted int32
	if int32(call(endpointVol, vtGetMute, uintptr(unsafe.Pointer(&muted)))) >= 0 && muted != 0 {
		return 0
	}

	var level float32
	if int32(call(endpointVol, vtGetMasterVolumeLevelScalar,
		uintptr(unsafe.Pointer(&level)))) < 0 {
		return -1
	}
	v := int(level*100 + 0.5)
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	return v
}
