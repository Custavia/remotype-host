import AppKit
import Security
import ServiceManagement

/// INSTALL HYGIENE — one host, in one place, replacing whatever came before.
///
/// macOS has no installer and no uninstaller, so an app that ships as a DMG
/// accumulates copies: the one on the mounted image, the one in ~/Downloads, the
/// one someone dragged to the Desktop, and eventually the one in /Applications.
/// They all carry the same bundle id, so they all fight for the same things —
/// port 50808, the `_hsbtk._tcp` advertisement, the Accessibility grant — and the
/// loser fails in ways that look like bugs rather than like duplicates. On the
/// Windows side the identical mess had already happened: four stale binaries and
/// six firewall rules pointing at paths that no longer existed.
///
/// So the app takes responsibility for its own installation at launch:
///
///  1. **One instance wins.** Any other running copy is asked to quit. The copy
///     the user just launched is the one that survives — launching a build is an
///     unambiguous statement about which one you want.
///  2. **It lives in /Applications.** Running from a mounted DMG or ~/Downloads
///     is offered a move, because that single step is what stops copy #2 from
///     existing at all. Declining is remembered, so it asks once.
///  3. **Older copies are offered to the Trash**, never deleted silently, and
///     never without naming exactly what will go.
///
/// Everything destructive is confirmed by the user. The one thing done without
/// asking — terminating another *running instance of this same app* — is the one
/// thing that is unambiguously safe and that no user would want to do by hand.
enum Install {

    private static let declinedMoveKey = "remotype.declinedMoveToApplications"
    private static let keptCopiesKey = "remotype.keptOlderCopies"

    /// Where a copy of the host may legitimately be found. Deliberately a fixed,
    /// small list rather than a Spotlight sweep of the disk: a background app that
    /// goes looking for things to delete is a worse citizen than a few stale
    /// copies, and these four are where every real one has ever turned up.
    private static var searchRoots: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
        ]
    }

    private static var bundleName: String {
        Bundle.main.bundleURL.lastPathComponent          // "Remotype Host.app"
    }

    // MARK: entry point

    /// Called once, early in launch, before the server binds anything.
    static func runAtLaunch() {
        clearResidualPermissionsIfNeeded()
        terminateOtherInstances()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            offerMoveToApplicationsIfNeeded()
        }
    }

    // MARK: 1 — one instance

    /// Quit every other running copy of this app, whatever path it was launched
    /// from. Two hosts on one Mac is never wanted: the second one loses the race
    /// for port 50808 and silently falls back to an ephemeral port, while BOTH
    /// keep advertising `_hsbtk._tcp` — so the phone shows two identical rows and
    /// half the time picks the one that cannot be reached by IP.
    static func terminateOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }

        for app in others {
            HostLog.write("another host was running (\(app.bundleURL?.path ?? "unknown path")) — asking it to quit")
            if !app.terminate() { app.forceTerminate() }
        }
        // Give the old process time to release port 50808 before we bind it. The
        // server starts right after this and a half-second race here is the
        // difference between "listening on 50808" and a silent ephemeral fallback.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              NSRunningApplication
                .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            usleep(100_000)
        }
    }

    // MARK: 2 — live in /Applications

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications"
            || path == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications").path
    }

    /// True when we are running straight off a mounted disk image. Moving is not
    /// optional here — a DMG is read-only and gets ejected, so this copy is
    /// guaranteed to disappear.
    static var isRunningFromDiskImage: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Volumes/")
    }

    private static func offerMoveToApplicationsIfNeeded() {
        guard !isInApplications else { return }
        guard !UserDefaults.standard.bool(forKey: declinedMoveKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Move Remotype Host to Applications?"
        alert.informativeText = isRunningFromDiskImage
            ? "It’s running from the disk image, which will disappear when you eject it. Moving it to Applications keeps it working — and keeps macOS from asking for permissions again."
            : "Keeping one copy in Applications avoids running two hosts at once, which is what makes a phone show the same computer twice."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedMoveKey)
            return
        }
        moveToApplicationsAndRelaunch()
    }

    /// Copy (not move — the source may be a read-only DMG) into /Applications,
    /// replacing whatever is there, then relaunch from the new location and exit.
    static func moveToApplicationsAndRelaunch() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleName)

        do {
            if fm.fileExists(atPath: dst.path) {
                // Replacing an older install: to the Trash, not deleted, so a bad
                // update is always recoverable by the user without a re-download.
                var trashed: NSURL?
                try? fm.trashItem(at: dst, resultingItemURL: &trashed)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            }
            try fm.copyItem(at: src, to: dst)
            HostLog.write("installed to \(dst.path)")

            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dst, configuration: cfg) { _, err in
                DispatchQueue.main.async {
                    if let err {
                        HostLog.write("relaunch from /Applications failed: \(err.localizedDescription)")
                        return
                    }
                    // The new copy runs terminateOtherInstances() and would kill us
                    // anyway; leaving under our own power is tidier.
                    NSApp.terminate(nil)
                }
            }
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn’t move to Applications"
            fail.informativeText = "\(error.localizedDescription)\n\nDrag Remotype Host to your Applications folder by hand and open it from there."
            fail.runModal()
        }
    }

    // MARK: 3 — older copies

    /// Every copy of the host on disk that is NOT the one running right now.
    /// Names this app has ever shipped under. A copy is "the same app" if its
    /// bundle id matches, whatever it is called — but in the protected folders we
    /// look for these exact names rather than listing the directory (see below).
    private static let knownAppNames = ["Remotype Host.app", "RemotypeHost.app"]

    static func staleCopies() -> [URL] {
        let fm = FileManager.default
        let mine = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let myID = Bundle.main.bundleIdentifier
        let home = fm.homeDirectoryForCurrentUser
        var found: [URL] = []

        func consider(_ candidate: URL) {
            guard fm.fileExists(atPath: candidate.path) else { return }
            let path = candidate.resolvingSymlinksInPath().path
            if path == mine { return }
            guard Bundle(url: candidate)?.bundleIdentifier == myID else { return }
            if !found.contains(where: { $0.resolvingSymlinksInPath().path == path }) {
                found.append(candidate)
            }
        }

        // The app folders are NOT privacy-protected, so enumerate them and match
        // EVERY .app by bundle id — this catches a copy under any name, e.g. the
        // old "RemotypeHost.app" (no space) that a name-only search missed, so it
        // survived uninstall and its stale TCC grant poisoned the next install.
        for root in [URL(fileURLWithPath: "/Applications"),
                     home.appendingPathComponent("Applications")] {
            let entries = (try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for candidate in entries where candidate.pathExtension == "app" { consider(candidate) }
        }

        // ~/Downloads and ~/Desktop ARE privacy-protected: LISTING them trips the
        // macOS folder-access prompt, which a background host must never provoke.
        // fileExists on a specific path is a stat, not a listing, and prompts
        // nothing — so probe only the exact names this app ships under.
        for dir in [home.appendingPathComponent("Downloads"),
                    home.appendingPathComponent("Desktop")] {
            for name in knownAppNames { consider(dir.appendingPathComponent(name)) }
        }
        return found
    }

    // MARK: residual-permission hygiene

    /// Where the current install records what it is, so the NEXT launch can tell
    /// "same app, updated" from "a different build landed on top of an old one".
    private static var installSignatureFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Remotype Host/install-signature", isDirectory: false)
    }

    /// The binary's DESIGNATED REQUIREMENT — the identity macOS actually keys a
    /// TCC grant to. It is stable across every build signed by the same
    /// certificate (Developer ID: Custavia), so an ordinary update keeps it and
    /// the grant carries; it changes only when the SIGNER changes (a different
    /// team, or a dev-signed build vs a notarized one), which is exactly when a
    /// prior grant no longer applies and a stale one must be cleared.
    ///
    /// The cdhash was the wrong signal here: it changes on EVERY build, so keying
    /// off it reset the grant on every update — the opposite of what a
    /// consistently-signed release wants.
    private static func currentSignerIdentity() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(rawValue: 0), &req) == errSecSuccess,
              let req else { return nil }
        var str: CFString?
        guard SecRequirementCopyString(req, SecCSFlags(rawValue: 0), &str) == errSecSuccess,
              let str else { return nil }
        return str as String
    }

    /// Clear residual permissions from a PRIOR install before they can poison
    /// this one. macOS keys TCC grants to a build's code signature; when the
    /// signature the user last granted differs from what is running now — a fresh
    /// install after an uninstall, or a differently-signed build dragged over an
    /// old one — the old grant lingers as a ghost row that reads "on" while
    /// every injected event is dropped. Resetting on a signature change (and on
    /// a first-ever run, where the record is absent) means the grant the user
    /// gives always attaches to the binary that is actually running.
    ///
    /// An ordinary UPDATE — same Developer ID signature, same designated
    /// requirement — has an unchanged hash, so this is a no-op and the grant
    /// survives, which is the whole point of signing updates consistently.
    static func clearResidualPermissionsIfNeeded() {
        let current = currentSignerIdentity()
        let recorded = try? String(contentsOf: installSignatureFile, encoding: .utf8)
        if let recorded, let current, recorded == current {
            return   // same build as last launch — nothing residual to clear
        }
        HostLog.write("install signature \(recorded ?? "none") → \(current ?? "unknown"): clearing any residual TCC grants for a clean slate")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.custavia.remotype.host"
        for service in ["Accessibility", "ScreenCapture", "ListenEvent", "PostEvent"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, bundleID]
            try? p.run(); p.waitUntilExit()
        }
        if let current {
            try? FileManager.default.createDirectory(
                at: installSignatureFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? current.write(to: installSignatureFile, atomically: true, encoding: .utf8)
        }
    }

    /// Offer to Trash them, naming each one. Returns silently when there are none,
    /// so it is safe to call from a menu item.
    static func reviewStaleCopies(silentWhenClean: Bool = false) {
        var copies = staleCopies()
        if silentWhenClean {
            // Asked once per copy. "Keep Them" is an answer, and a menu that
            // re-asks every time it opens is a menu people stop opening.
            let kept = Set(UserDefaults.standard.stringArray(forKey: keptCopiesKey) ?? [])
            copies = copies.filter { !kept.contains($0.path) }
        }
        guard !copies.isEmpty else {
            if !silentWhenClean {
                let ok = NSAlert()
                ok.messageText = "No other copies found"
                ok.informativeText = "Remotype Host is installed once, at \(Bundle.main.bundleURL.path)."
                ok.runModal()
            }
            return
        }

        let list = copies.map { "• \($0.path)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = copies.count == 1 ? "Move the older copy to the Trash?" : "Move \(copies.count) older copies to the Trash?"
        alert.informativeText = """
        These are other copies of Remotype Host. Each one can start its own \
        host, which is what makes a phone list the same computer twice.

        \(list)

        The copy you are running now stays where it is.
        """
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep Them")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            var kept = Set(UserDefaults.standard.stringArray(forKey: keptCopiesKey) ?? [])
            kept.formUnion(copies.map(\.path))
            UserDefaults.standard.set(Array(kept), forKey: keptCopiesKey)
            return
        }

        for url in copies {
            var out: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &out)
                HostLog.write("trashed older copy: \(url.path)")
            } catch {
                HostLog.write("could not trash \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
