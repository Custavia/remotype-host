//go:build linux

// System-tray UI for the Linux host — the same shape as the macOS menu bar and
// the Windows tray, built on the same fyne.io/systray library the Windows host
// uses so the three stay in step. Shown on a desktop; skipped on a headless
// server (see hasDesktopSession in main.go).
//
// A Linux tray is a StatusNotifierItem over D-Bus. It appears wherever the
// desktop has a status-notifier host: KDE and most panels, XFCE with the
// Status Notifier plugin, sway with waybar. GNOME needs the AppIndicator
// extension. Where there is no host the process still runs — the icon simply
// has nowhere to show, and the log carries the pairing code as it always did.
package main

import (
	_ "embed"
	"fmt"

	"fyne.io/systray"
)

//go:embed trayicon.png
var trayIcon []byte

// runTray shows the tray icon and menu and blocks on the systray event loop.
func runTray() { systray.Run(onTrayReady, onTrayExit) }

var (
	trayPairedParent *systray.MenuItem
	trayForgetAll    *systray.MenuItem
	trayInjectWarn   *systray.MenuItem
)

func onTrayReady() {
	systray.SetIcon(trayIcon)
	systray.SetTitle("Remotype Host")
	systray.SetTooltip(fmt.Sprintf("Remotype Host — port %d · Wi-Fi required, internet never", listenPort))

	// Status + the LAN promise, both read-only, matching the top of the macOS
	// popover and the Windows tray.
	mStatus := systray.AddMenuItem(fmt.Sprintf("Listening on port %d", listenPort), "")
	mStatus.Disable()
	// The one state that used to be invisible: launched from the desktop with
	// no uinput access, the old host printed to a console nobody had and
	// exited. Now it stays up and this row says why typing does nothing yet.
	// Cleared by the retry loop in main the moment access appears.
	trayInjectWarn = systray.AddMenuItem("⚠ Can’t type yet — no access to /dev/uinput",
		"Add yourself to the 'input' group and install the udev rule (see the README), then log out and back in. This clears by itself once access appears.")
	trayInjectWarn.Disable()
	if !injectBlocked.Load() {
		trayInjectWarn.Hide()
	}
	mLAN := systray.AddMenuItem("Wi-Fi required · internet never used",
		"Remotype Host talks only to devices on your local network")
	mLAN.Disable()
	if !layoutIsUS() {
		mLayout := systray.AddMenuItem("Keyboard layout: "+layoutDisplayName(), "The layout your typing is mapped to")
		mLayout.Disable()
	}

	systray.AddSeparator()

	// Pairing — the heart of RT1 for the user: which phones may type here, and
	// taking that back. "Pair a phone…" always mints a fresh code (the user
	// came here on purpose) and shows it the Linux way: the terminal and, where
	// libnotify exists, a desktop notification.
	mPair := systray.AddMenuItem("Pair a phone…", "Show a code to type on your phone")
	trayPairedParent = systray.AddMenuItem("Paired phones", "Phones allowed to control this computer")
	trayForgetAll = trayPairedParent.AddSubMenuItem("Remove all phones", "Every phone will have to pair again")
	rebuildTrayPaired()
	// Redraw the paired list, and only that, whenever pairings change.
	pairing.setOnChange(rebuildTrayPaired)

	systray.AddSeparator()
	mAbout := systray.AddMenuItem("About Remotype Host", "")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop the host and quit")

	go func() {
		for {
			select {
			case <-mPair.ClickedCh:
				pairing.show()
				showPairingWindow()
			case <-trayForgetAll.ClickedCh:
				identity.forgetAll()
				rebuildTrayPaired()
			case <-mAbout.ClickedCh:
				showAbout()
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

func onTrayExit() {
	zcMu.Lock()
	if zcServer != nil {
		zcServer.Shutdown()
	}
	zcMu.Unlock()
}

// maxTrayPaired caps the pre-created removal rows. A phone count past this is
// far beyond any real use; the identity store still holds them all.
const maxTrayPaired = 16

var trayPairedRows []*trayPairedRow

type trayPairedRow struct {
	item *systray.MenuItem
	dev  string
}

// rebuildTrayPaired refreshes the "Paired phones" submenu: one "Remove <name>"
// row per phone. The rows are created once and shown/hidden, because
// fyne.io/systray cannot delete a menu item — the same approach as the Windows
// tray.
func rebuildTrayPaired() {
	if trayPairedParent == nil {
		return
	}
	if trayPairedRows == nil {
		for i := 0; i < maxTrayPaired; i++ {
			row := &trayPairedRow{item: trayPairedParent.AddSubMenuItem("", "Remove this phone")}
			row.item.Hide()
			trayPairedRows = append(trayPairedRows, row)
			go func(r *trayPairedRow) {
				for range r.item.ClickedCh {
					if r.dev != "" {
						identity.forget(r.dev)
						rebuildTrayPaired()
					}
				}
			}(row)
		}
	}
	devices := identity.list()
	for i, row := range trayPairedRows {
		if i < len(devices) {
			row.dev = devices[i].Dev
			row.item.SetTitle("Remove " + devices[i].Name)
			row.item.Show()
		} else {
			row.dev = ""
			row.item.Hide()
		}
	}
	if len(devices) == 0 {
		trayForgetAll.Hide()
	} else {
		trayForgetAll.Show()
	}
}

// showAbout surfaces version, support and the LAN promise. A desktop
// notification where notify-send exists (the same surface the pairing code
// uses), and the log either way.
func showAbout() {
	body := fmt.Sprintf("Version %s\n%s\nWi-Fi required · internet never used",
		appVersion, appSupport)
	logf("About: Remotype Host %s (%s)", appVersion, appSupport)
	notifyDesktop("Remotype Host", body)
}

// trayClearInjectWarning hides the uinput warning row. Safe from any
// goroutine and before the tray exists — the row also starts hidden when
// injectBlocked is already false by the time the tray builds.
func trayClearInjectWarning() {
	if trayInjectWarn != nil {
		trayInjectWarn.Hide()
	}
}
