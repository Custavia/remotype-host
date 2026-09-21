//go:build windows

// System-tray (notification area) UI for the Windows host. Replaces the console
// window: built with `-H windowsgui` there's no terminal — just a tray icon with
// a right-click menu (Re-advertise / About / Quit). Logs go to the file set up
// in initLog(). The About box is a native Win32 MessageBox.
package main

import (
	_ "embed"
	"fmt"
	"sync"

	"fyne.io/systray"
)

//go:embed tray.ico
var trayIcon []byte

// user32 is declared in inject_windows.go (same package + build tag).
var procMessageBoxW = user32.NewProc("MessageBoxW")

const (
	mbOk            = 0x00000000
	mbIconInfo      = 0x00000040
	mbSetForeground = 0x00010000
	mbTopmost       = 0x00040000
)

// runTray shows the tray icon + menu and blocks on the systray event loop (the
// TCP accept loop runs on its own goroutine from startServer).
func runTray() { systray.Run(onTrayReady, onTrayExit) }

func onTrayReady() {
	systray.SetIcon(trayIcon)
	systray.SetTitle("Remotype Host")
	systray.SetTooltip(fmt.Sprintf("Remotype Host — port %d · Wi-Fi required, internet never", listenPort))

	mStatus := systray.AddMenuItem(fmt.Sprintf("Running · port %d", listenPort), "")
	mLAN := systray.AddMenuItem("Wi-Fi required · internet never used", "Remotype Host talks only to devices on your network")
	mLAN.Disable()
	mStatus.Disable()
	// Hidden until a phone too old for RT1 connects. See trayLegacyPhone.
	mOldPhone := systray.AddMenuItem("", "")
	mOldPhone.Disable()
	mOldPhone.Hide()
	trayMu.Lock()
	trayOldPhone = mOldPhone
	trayMu.Unlock()
	// Hidden until a cast session is active — then "Casting to <TV> — Stop"
	// (docs/CASTING.md §9.3: the only stop affordance that survives a dead phone).
	mCast := systray.AddMenuItem("", "Stop casting to your TV")
	mCast.Hide()
	trayMu.Lock()
	trayCast = mCast
	trayMu.Unlock()
	systray.AddSeparator()
	// Paired phones. This section is the whole point of RT1 from the user's
	// side: it is where they see which phones are allowed to type on this PC,
	// and where they take that back.
	mPair := systray.AddMenuItem("Pair a phone…", "Show a code to type on your phone")
	mPaired := systray.AddMenuItem("Paired phones", "Phones allowed to control this PC")
	mForgetAll := mPaired.AddSubMenuItem("Remove all phones", "Every phone will have to pair again")
	rebuildPairedMenu(mPaired, mForgetAll)
	pairing.setOnChange(func() { rebuildPairedMenu(mPaired, mForgetAll) })

	systray.AddSeparator()
	mSetup := systray.AddMenuItem("Set up Remotype Host…",
		"Walk through firewall access and connecting your phone, one step at a time")
	mReadv := systray.AddMenuItem("Re-advertise on network", "Re-announce so your phone can rediscover this PC")
	mFixFw := systray.AddMenuItem("Repair firewall access",
		"Rewrite the Windows Firewall rules — use this if your phone cannot find this PC")
	mActivity := systray.AddMenuItem("Show activity", "Open a live log of connections, mode switches and casts")
	mAbout := systray.AddMenuItem("About Remotype Host", "")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop the host and quit")

	go func() {
		for {
			select {
			case <-mCast.ClickedCh:
				castShutdown()
			case <-mPair.ClickedCh:
				// Always mint a NEW code from the tray: the user came here
				// deliberately, and "I mistyped it twice and don't know how
				// many tries are left" has exactly one good answer.
				pairing.show()
				showPairingWindow()
			case <-mForgetAll.ClickedCh:
				identity.forgetAll()
				rebuildPairedMenu(mPaired, mForgetAll)
			case <-mActivity.ClickedCh:
				if activityVisible() {
					hideActivity()
					mActivity.SetTitle("Show activity")
				} else {
					showActivity()
					mActivity.SetTitle("Hide activity")
				}
			case <-mSetup.ClickedCh:
				showSetupWizard()
			case <-mFixFw.ClickedCh:
				// Sits directly above Re-advertise because the two are the
				// answer to the same complaint ("my phone can't see this PC"),
				// and this is the one that fixes the cause people cannot see:
				// a BLOCK rule written by clicking Cancel on Windows' own
				// firewall prompt.
				if err := repairFirewall(); err != nil {
					logf("firewall repair could not start: %v", err)
				}
			case <-mReadv.ClickedCh:
				reAdvertise()
			case <-mAbout.ClickedCh:
				go showAbout()
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

// onTrayExit tears down any active cast session, cleanly deregisters the
// Bonjour service, then lets main() return (which exits the process).
func onTrayExit() {
	castShutdown()
	zcMu.Lock()
	if zcServer != nil {
		zcServer.Shutdown()
	}
	zcMu.Unlock()
}

// The "Casting to <TV> — Stop" row, driven by the cast controller.
var (
	trayMu       sync.Mutex
	trayCast     *systray.MenuItem
	trayOldPhone *systray.MenuItem
)

// trayLegacyPhone shows the one thing the phone itself cannot say.
func trayLegacyPhone(name string) {
	trayMu.Lock()
	item := trayOldPhone
	trayMu.Unlock()
	if item == nil {
		return
	}
	item.SetTitle(name + " is too old to pair — update Remotype on it")
	item.SetTooltip("This PC now requires a paired phone. Until that phone updates, nothing it sends is accepted.")
	item.Show()
}

// trayCastUpdate shows/hides the cast row as the session starts/ends.
func trayCastUpdate(active bool, name string) {
	trayMu.Lock()
	item := trayCast
	trayMu.Unlock()
	if item == nil {
		return
	}
	if active {
		item.SetTitle("Casting to " + name + " — Stop")
		item.Show()
	} else {
		item.Hide()
	}
}

// showAbout opens the Custavia-branded About window (see about_windows.go).
func showAbout() {
	showAboutWindow()
}

// The per-device rows under "Paired phones".
//
// systray has no way to REMOVE a menu item once added, so the rows are created
// once, up to a fixed maximum, and shown/hidden as the list changes. Each row
// keeps its own click goroutine alive for the life of the process, reading the
// device id it currently represents through a mutex — a row that is hidden
// simply never fires.
var (
	pairedRowsMu sync.Mutex
	pairedRows   []*pairedRow
)

const maxPairedRows = 8

type pairedRow struct {
	item *systray.MenuItem
	dev  string
}

func rebuildPairedMenu(parent, forgetAll *systray.MenuItem) {
	pairedRowsMu.Lock()
	if pairedRows == nil {
		for i := 0; i < maxPairedRows; i++ {
			row := &pairedRow{item: parent.AddSubMenuItem("", "Remove this phone")}
			row.item.Hide()
			pairedRows = append(pairedRows, row)
			go func(r *pairedRow) {
				for range r.item.ClickedCh {
					pairedRowsMu.Lock()
					dev := r.dev
					pairedRowsMu.Unlock()
					if dev == "" {
						continue
					}
					identity.forget(dev)
					rebuildPairedMenu(parent, forgetAll)
				}
			}(row)
		}
	}
	rows := pairedRows
	pairedRowsMu.Unlock()

	devices := identity.list()
	pairedRowsMu.Lock()
	for i, row := range rows {
		if i < len(devices) {
			row.dev = devices[i].Dev
			row.item.SetTitle("Remove " + devices[i].Name)
			row.item.Show()
		} else {
			row.dev = ""
			row.item.Hide()
		}
	}
	pairedRowsMu.Unlock()

	if len(devices) == 0 {
		parent.SetTitle("Paired phones — none yet")
		forgetAll.Hide()
	} else if len(devices) == 1 {
		parent.SetTitle("Paired phones — 1")
		forgetAll.Show()
	} else {
		parent.SetTitle(fmt.Sprintf("Paired phones — %d", len(devices)))
		forgetAll.Show()
	}
}
