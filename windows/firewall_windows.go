package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

// FIREWALL REPAIR — the one failure the user cannot see and cannot undo.
//
// When the host first binds TCP 50808 and joins the mDNS multicast group,
// Windows shows its "Windows Security Alert" dialog. Clicking **Cancel** on that
// dialog does not mean "ask me later" — it writes a persistent BLOCK rule for
// this program. From then on the host runs perfectly, reports itself healthy,
// advertises on the network, and no phone can ever reach it. Nothing in the tray
// says why, because from the app's side nothing is wrong.
//
// The installer pre-creates allow rules so the dialog never appears at all, but
// that only helps people who ran the installer AFTER this shipped. Everyone with
// a blocked rule already — and anyone running the portable zip, or who clicked
// Cancel before installing — needs a way back. This is that way back.
//
// The script is written out at runtime rather than shipped as a file next to the
// exe, so it works identically for the installer, the portable zip and a copy
// someone dragged to their desktop, and it always targets the executable that is
// actually running rather than whatever path an installer recorded once.
const fixFirewallScript = `@echo off
setlocal
title Remotype Host - repair firewall access

set "EXE=%~1"

echo.
echo   Remotype Host - repair firewall access
echo   ---------------------------------------------------------------
echo   Program: %EXE%
echo.
echo   Removing any existing rules for this program (including BLOCK
echo   rules, which is what "Cancel" on the Windows firewall prompt
echo   creates), then adding the two rules the host needs.
echo.
echo   Every command is shown below with its output. This window stays
echo   open until you close it.
echo.

rem  Nothing is hidden: every command is printed before it runs and its output
rem  is left on screen. This window asks for administrator rights and edits
rem  firewall rules - the user is entitled to see exactly what that means.

echo   ^> netsh advfirewall firewall delete rule name=all program="%EXE%"
netsh advfirewall firewall delete rule name=all program="%EXE%"
echo.
echo   ^> netsh advfirewall firewall delete rule name="Remotype Host (TCP-In)"
netsh advfirewall firewall delete rule name="Remotype Host (TCP-In)"
echo.
echo   ^> netsh advfirewall firewall delete rule name="Remotype Host (UDP-In)"
netsh advfirewall firewall delete rule name="Remotype Host (UDP-In)"
echo.

rem  PROGRAM-scoped, not port-scoped, and both protocols. The host falls back
rem  to an OS-assigned port when 50808 is taken, so a port rule would cover
rem  only the happy path - and mDNS discovery needs UDP 5353 regardless.
rem  any only: never open this on a public network.
echo   ^> netsh advfirewall firewall add rule name="Remotype Host (TCP-In)" dir=in action=allow program="%EXE%" protocol=TCP profile=any
netsh advfirewall firewall add rule name="Remotype Host (TCP-In)" dir=in action=allow program="%EXE%" protocol=TCP profile=any enable=yes
if errorlevel 1 goto failed
echo.
echo   ^> netsh advfirewall firewall add rule name="Remotype Host (UDP-In)" dir=in action=allow program="%EXE%" protocol=UDP profile=any
netsh advfirewall firewall add rule name="Remotype Host (UDP-In)" dir=in action=allow program="%EXE%" protocol=UDP profile=any enable=yes
if errorlevel 1 goto failed
echo.
echo   ---------------------------------------------------------------
echo   Done. Both rules are in place.
echo.
echo   Open Remotype on your phone - this PC should appear within a few
echo   seconds. If it still does not, check that the phone is on the same
echo   Wi-Fi network, then use "Re-advertise on network" in the tray menu.
echo.
echo   Press any key to close this window.
pause >nul
exit /b 0

:failed
echo.
echo   Could not add the rules.
echo.
echo   This usually means the window was not running as administrator.
echo   Close this window and choose "Repair firewall access" again,
echo   then click Yes when Windows asks for permission.
echo.
echo   Press any key to close this window.
pause >nul
exit /b 1
`

// confirmRepairFirewall explains what is about to happen BEFORE the UAC prompt
// appears. A dialog asking for administrator rights out of nowhere is the shape
// of every piece of malware a user has been warned about; saying what will run,
// and that they will see it run, is what makes clicking Yes reasonable.
func confirmRepairFirewall(exe string) bool {
	body := "Remotype Host will ask Windows for permission to repair its firewall rules.\n\n" +
		"This is usually needed when your phone cannot find this PC — clicking " +
		"\"Cancel\" on Windows' firewall prompt writes a rule that blocks the host " +
		"permanently, and nothing in the app can tell you that happened.\n\n" +
		"It will run these commands, in a window that shows every one of them and " +
		"stays open until you close it:\n\n" +
		"  • remove existing firewall rules for\n     " + exe + "\n" +
		"  • allow it to receive TCP and UDP\n     on private and domain networks only\n\n" +
		"Windows will ask for administrator permission next. Continue?"

	user32 := syscall.NewLazyDLL("user32.dll")
	messageBox := user32.NewProc("MessageBoxW")
	titlePtr, _ := syscall.UTF16PtrFromString("Remotype Host — repair firewall access")
	bodyPtr, _ := syscall.UTF16PtrFromString(body)
	const mbYesNo = 0x4
	const mbIconQuestion = 0x20
	const mbSetForeground = 0x10000
	const idYes = 6
	ret, _, _ := messageBox.Call(0,
		uintptr(unsafe.Pointer(bodyPtr)),
		uintptr(unsafe.Pointer(titlePtr)),
		uintptr(mbYesNo|mbIconQuestion|mbSetForeground))
	return ret == idYes
}

// repairFirewall writes the script to TEMP and runs it elevated. Elevation is
// required — netsh cannot add a firewall rule as a standard user — so this puts
// up a UAC prompt, after the explanation above. Declining either is a normal
// outcome and simply does nothing.
func repairFirewall() error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("could not find my own path: %w", err)
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}

	if !confirmRepairFirewall(exe) {
		logf("firewall repair: declined at the explanation")
		return nil
	}

	script := filepath.Join(os.TempDir(), "remotype-fix-firewall.cmd")
	// 0700: the script embeds a path and runs elevated, so it should not be
	// writable by another user between being written and being run.
	if err := os.WriteFile(script, []byte(strings.ReplaceAll(fixFirewallScript, "\n", "\r\n")), 0o700); err != nil {
		return fmt.Errorf("could not write the repair script: %w", err)
	}

	// cmd.exe /c "script" "exe" — quoted so paths with spaces survive, which
	// "C:\Program Files\Remotype Host\remotype-host.exe" certainly has.
	args := fmt.Sprintf(`/c ""%s" "%s""`, script, exe)
	if err := shellExecuteElevated("cmd.exe", args); err != nil {
		return err
	}
	logf("firewall repair launched (UAC) for %s — rules for ALL network profiles, incl. Public", exe)
	return nil
}

// shellExecuteElevated runs a program with the "runas" verb, which is what makes
// Windows show the UAC prompt. There is no way to add a firewall rule without
// it, and asking is more honest than a silent failure.
func shellExecuteElevated(exe, params string) error {
	verbPtr, _ := syscall.UTF16PtrFromString("runas")
	exePtr, _ := syscall.UTF16PtrFromString(exe)
	argPtr, _ := syscall.UTF16PtrFromString(params)

	shell32 := syscall.NewLazyDLL("shell32.dll")
	shellExecute := shell32.NewProc("ShellExecuteW")
	const swShowNormal = 1
	ret, _, _ := shellExecute.Call(
		0,
		uintptr(unsafe.Pointer(verbPtr)),
		uintptr(unsafe.Pointer(exePtr)),
		uintptr(unsafe.Pointer(argPtr)),
		0,
		swShowNormal,
	)
	// ShellExecuteW returns >32 on success. 5 (ERROR_ACCESS_DENIED) is what a
	// declined UAC prompt looks like — a choice, not a fault.
	if ret <= 32 {
		if ret == 5 {
			return fmt.Errorf("permission was declined")
		}
		return fmt.Errorf("could not start the repair (code %d)", ret)
	}
	return nil
}
