import AppKit
import ServiceManagement

/// LAUNCH AT LOGIN, and the removal story that has to exist beside it.
///
/// The host had neither. Every reboot silently ended the pairing, and because
/// `LSUIElement` means there is no Dock icon, nothing on screen said so — the
/// phone simply stopped finding the computer, which reads as a bug in the phone.
///
/// `SMAppService.mainApp` is the right primitive here, not `.agent(plistName:)`
/// and not a hand-written `~/Library/LaunchAgents` plist. Those exist to launch a
/// *separate headless helper*; Remotype's menu-bar app IS the background service.
/// `mainApp` registers the app itself, appears in System Settings ▸ General ▸
/// Login Items under its own name where the user can turn it off, unregisters
/// cleanly, and leaves no file behind for an uninstaller to have to know about.
/// It also does not touch the code signature, so the Accessibility and Screen
/// Recording grants are unaffected — worth stating given how easily this app's
/// TCC grants go stale.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn it on or off, surfacing the two failures that actually happen instead
    /// of swallowing them into a silent no-op.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                // `.requiresApproval` means the user switched it off in System
                // Settings. Calling register() again will not override that — the
                // only honest move is to send them to the pane.
                if SMAppService.mainApp.status == .requiresApproval {
                    showApprovalNeeded()
                    return false
                }
                try SMAppService.mainApp.register()
                HostLog.write("start at login: enabled")
            } else {
                try SMAppService.mainApp.unregister()
                HostLog.write("start at login: disabled")
            }
            return true
        } catch {
            // Code 1 here almost always means the app is not in /Applications, or
            // is still quarantined — the launch-services database will not
            // register a bundle it considers untrusted or transient.
            let alert = NSAlert()
            alert.messageText = "Couldn’t change “Start at login”"
            alert.informativeText = Install.isInApplications
                ? error.localizedDescription
                : "Move Remotype Host to your Applications folder first — macOS won’t start an app at login from \(Bundle.main.bundleURL.deletingLastPathComponent().path)."
            alert.runModal()
            HostLog.write("start at login failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func showApprovalNeeded() {
        let alert = NSAlert()
        alert.messageText = "Turn it on in System Settings"
        alert.informativeText = "Remotype Host was switched off in Login Items. Open System Settings ▸ General ▸ Login Items & Extensions and enable it there."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

/// UNINSTALL — the thing macOS has no convention for.
///
/// Dragging the app to the Trash leaves two things behind that matter, and one
/// of them causes a support issue this project has already had: TCC grants
/// persist as ghost rows keyed to the old code signature, so a later reinstall
/// can land on a stale grant whose signature no longer matches. The toggle then
/// reads "on" in System Settings while every injected event is silently dropped.
/// `tccutil reset` forecloses that, needs no admin rights, and is the single
/// reason an in-app uninstall is worth more here than a Finder drag.
///
/// What it deliberately does NOT remove: files received from the phone in
/// ~/Downloads/Remotype. Those belong to the user, not to the app.
enum Uninstaller {

    static func run() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Remotype Host?"
        alert.informativeText = """
        This will:
        • quit the host and stop it starting at login
        • reset its Accessibility and Screen Recording permissions
        • forget every paired phone and all settings
        • move the app to the Trash

        Files your phone sent to this Mac are kept in your Downloads folder.
        """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Order matters. The login-item registration lives in a launchd database
        // no shell script can reach once the bundle is gone, so it has to go
        // first, from inside the running app.
        try? SMAppService.mainApp.unregister()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.custavia.remotype.host"
        for service in ["Accessibility", "ScreenCapture", "ListenEvent", "PostEvent"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, bundleID]
            try? p.run()
            p.waitUntilExit()
        }
        HostLog.write("uninstall: login item removed, TCC grants reset")

        // Everything the host ever wrote for itself. A "complete uninstall" that
        // leaves the identity behind would silently keep the phones paired to a
        // Mac the user believes is clean; leaving the preferences behind would
        // skip the welcome flow on a reinstall. Downloads are the user's, kept.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        CFPreferencesAppSynchronize(bundleID as CFString)
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let leftovers: [URL] = [
            library.appendingPathComponent("Application Support/Remotype Host"),
            library.appendingPathComponent("Preferences/\(bundleID).plist"),
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("HTTPStorages/\(bundleID)"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
        ]
        for url in leftovers where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        var targets = Install.staleCopies()
        targets.append(Bundle.main.bundleURL)
        for url in targets {
            var out: NSURL?
            try? fm.trashItem(at: url, resultingItemURL: &out)
        }

        // The preferences domain is owned by cfprefsd, which flushes the app's
        // cached defaults (window frames and the like) back to disk
        // AFTER the process exits — deleting the plist from inside the app leaves
        // a freshly rewritten one behind. So the final sweep runs detached, after
        // we are gone: the domain via `defaults delete` (the cfprefsd-aware way),
        // then the plist and the log.
        let plist = library.appendingPathComponent("Preferences/\(bundleID).plist").path
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/bin/sh")
        sweep.arguments = ["-c", """
            sleep 2
            /usr/bin/defaults delete '\(bundleID)' >/dev/null 2>&1
            /bin/rm -f '\(plist)' '\(HostLog.path)'
            """]
        try? sweep.run()
        NSApp.terminate(nil)
    }
}
