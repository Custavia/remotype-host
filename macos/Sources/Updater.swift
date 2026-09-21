import AppKit
import SwiftUI

/// UPDATES WITHOUT THE HOST EVER TOUCHING THE INTERNET.
///
/// Remotype Host opens exactly one kind of network connection: to the phones and
/// TVs on the same Wi-Fi. That is the product's whole privacy promise — nothing
/// you type or show ever leaves your network — and an auto-updater that polls a
/// release feed would quietly break it. An earlier version embedded an updater
/// that checked for a new build once a day; that is gone.
///
/// So the host does not check for updates itself, because it cannot without
/// reaching the internet. Two things replace it, and neither costs the promise:
///
///  - **"Check for updates…"** opens the download page in the user's browser,
///    which does have internet. The host makes no request; the browser does.
///  - **The phone app** is online anyway (it is how people install the host in
///    the first place). It compares the host version it learns on connect against
///    the latest, and tells the user when a newer host is worth downloading.
///
/// Updating is still a drag-over-the-old-copy install, and `Install.swift` keeps
/// exactly one copy at one path — so the Accessibility and Screen Recording
/// grants survive, since TCC keys them to the code signature and the path.
enum HostUpdate {

    /// The product page, where the signed download lives. Opened in the browser,
    /// never fetched by the host.
    static let downloadPage = URL(string: "https://remotype.custavia.com/")!

    static func openDownloadPage() {
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(downloadPage)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
