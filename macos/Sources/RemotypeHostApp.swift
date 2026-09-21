import ApplicationServices
import SwiftUI

/// `RemotypeHost --tcc-probe`: answer the TCC questions and exit, before any of
/// AppKit wakes up.
///
/// Exists because BOTH in-process answers cache for the life of the process on
/// current macOS: `AXIsProcessTrusted()` famously, and — despite years of it
/// behaving live — `CGPreflightPostEventAccess()` too. A host that is running
/// while the user flips the switch can therefore never see the grant arrive,
/// which left the permission wizard saying "waiting for the switch" at a switch
/// that was already on. A child process pays none of that: it is born after the
/// grant, asks fresh, and reports what the TCC database actually says now. The
/// wizard polls this instead of trusting its own stale view.
///
/// The exit code is a bitmask, not a bool, so one spawn answers every step:
/// bit 0 = Accessibility (AX list), bit 1 = post-event access (what injection
/// actually needs), bit 2 = Screen Recording.
enum TCCProbe {
    static let axBit: Int32 = 1, postEventBit: Int32 = 2, screenBit: Int32 = 4

    static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--tcc-probe") else { return }
        var mask: Int32 = 0
        if AXIsProcessTrusted() { mask |= axBit }
        if CGPreflightPostEventAccess() { mask |= postEventBit }
        if CGPreflightScreenCaptureAccess() { mask |= screenBit }
        exit(mask)
    }
}

/// The real entry point. The probe check must run before SwiftUI builds the
/// App — a probe that reached `MenuBarExtra` would flash a second menu-bar
/// icon a few times a second while the wizard polls.
@main
enum Boot {
    static func main() {
        TCCProbe.runIfAsked()
        RemotypeHostApp.main()
    }
}

/// Runs before any window or the server exists — the only place install hygiene
/// can happen early enough to matter, since an older copy still holding port
/// 50808 has to be gone BEFORE this one tries to bind it.
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Offscreen UI snapshots: `RemotypeHost --snapshot <dir>` writes each
        // window's design to a PNG and exits.
        //
        // Not a nicety. This is a menu-bar app whose windows can only be reached
        // by granting permissions or by pairing a phone, on a Mac that has to be
        // unlocked and awake — so "I changed the window and never looked at it"
        // is the default outcome, which is precisely the failure the permission
        // wizard exists to fix. Inert unless the flag is passed.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            UISnapshot.writeAll(to: args[i + 1])
            exit(0)
        }

        // Before anything else: prove this build's crypto agrees with the spec.
        // A drift between the Swift, Go and Kotlin implementations shows up in
        // the field as "connects, then dies, on one platform only" — this turns
        // it into one line in the log.
        RT1SelfTest.run()
        Install.runAtLaunch()
    }
}

struct RemotypeHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @StateObject private var server = Server()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(server: server)
        } label: {
            MenuBarLabel(server: server)
        }
        .menuBarExtraStyle(.window)

        // Custavia-branded About window, opened from the menu-bar "About" item.
        Window("About Remotype Host", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        // Live activity — connections, mode switches, TV/cast toggles. The same
        // lines HostLog persists, surfaced on demand (Windows-host parity:
        // its tray gained "Show activity").
        Window("Remotype — Activity", id: "activity") {
            ActivityView()
        }

        // Shown once, on the very first launch. See WelcomeView for why a
        // menu-bar app needs one at all.
        Window("Welcome to Remotype Host", id: "welcome") {
            WelcomeView(server: server)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar glyph — and the only view guaranteed to exist at launch, which
/// is what makes it the right place to hang the first-run window off. A menu-bar
/// app has no window to put an `.onAppear` on, and `openWindow` is a SwiftUI
/// Environment value an AppDelegate cannot reach.
struct MenuBarLabel: View {
    @ObservedObject var server: Server
    @Environment(\.openWindow) private var openWindow
    private static let shownKey = "remotype.didShowWelcome"

    var body: some View {
        // The keyboard glyph the host has always used, now badged with the
        // brand "R" so the menu bar carries the same mark as the app.
        Image(nsImage: TrayIcon.make())
            .help("Remotype Host — \(HostTrust.lanFootnote)")
            .onAppear {
                let d = UserDefaults.standard
                // Set by the wizard right before it relaunches the app to make a
                // grant take effect — the new process must pick the flow back up,
                // or "Restart and finish" finishes nothing.
                let resume = d.bool(forKey: PermissionWizard.resumeAfterRelaunchKey)
                if resume { d.removeObject(forKey: PermissionWizard.resumeAfterRelaunchKey) }

                // A beat, so the window lands after the menu-bar item exists and
                // the arrow in it points at something already on screen.
                if !d.bool(forKey: Self.shownKey) {
                    d.set(true, forKey: Self.shownKey)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        DockPresence.enterWindowMode()
                        openWindow(id: "welcome")
                    }
                } else if resume || !server.accessibilityTrusted {
                    // NOT first launch, and yet the host cannot type. The welcome
                    // flag lives in preferences, which survive deleting the app —
                    // so on a reinstall the old gate concluded "already set up"
                    // and showed nothing, in front of a host with no permissions.
                    // The grant itself is the truth worth gating on: while the
                    // required one is missing this app is a menu-bar icon that
                    // does nothing, and the wizard IS the product's first
                    // experience. (Deliberate decliners see it once per launch,
                    // and it closes; that trade is taken knowingly.)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        PermissionWizard.present(server: server)
                    }
                }
            }
    }
}

struct MenuContent: View {
    @ObservedObject var server: Server
    @Environment(\.openWindow) private var openWindow
    @State private var startsAtLogin = LoginItem.isEnabled
    @ObservedObject private var paired = PairedDevices.shared

    private var permissionsAllSet: Bool {
        server.accessibilityTrusted && server.screenRecordingTrusted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Brand row — same mark and wordmark casing as the phone's home screen.
            HStack(spacing: 8) {
                HostBrandMark(size: 22)
                Text("REMOTYPE HOST")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(HostDeck.legend)
                Spacer(minLength: 0)
            }

            statusLine(server.listening
                       ? (server.listenPort.map { "Listening on port \($0)" } ?? "Listening for iPhone…")
                       : "Starting…",
                       symbol: server.listening ? "wifi" : "hourglass",
                       tint: server.listening ? HostDeck.statusGreen : HostDeck.sublegend)
            if let p = server.listenPort, p != Server.preferredPort {
                statusLine("Port \(Server.preferredPort) was busy — dial \(p) by IP",
                           symbol: "exclamationmark.triangle.fill", tint: HostDeck.statusAmber)
            }
            if let old = server.legacyPhoneName {
                statusLine("\(old) is too old to pair — update Remotype on it",
                           symbol: "exclamationmark.triangle.fill", tint: HostDeck.statusAmber)
                hint("This computer now requires a paired phone. Until that phone updates, nothing it sends will be accepted.")
            }
            statusLine(server.clientName.map { "Connected: \($0)" } ?? "No device connected",
                       symbol: server.clientName != nil ? "iphone" : "iphone.slash",
                       tint: server.clientName != nil ? HostDeck.statusGreen : HostDeck.sublegend)

            LANCard(compact: true)

            rule

            // Status only. The ACTION is one button, and it opens the wizard —
            // two "Grant …" buttons plus two lines of instructions is exactly
            // the checklist people were getting lost in, and the menu is the
            // worst possible place to read a procedure.
            if server.accessibilityTrusted {
                statusLine("Accessibility granted", symbol: "checkmark.seal.fill",
                           tint: HostDeck.statusGreen)
            } else {
                statusLine("Accessibility needed to type and click",
                           symbol: "exclamationmark.triangle.fill", tint: HostDeck.statusAmber)
            }
            if server.screenRecordingTrusted {
                statusLine("Screen Recording granted (screen + sound)",
                           symbol: "checkmark.seal.fill", tint: HostDeck.statusGreen)
            } else {
                statusLine("Screen Recording off — no screen or sound",
                           symbol: "rectangle.dashed.badge.record", tint: HostDeck.sublegend)
            }

            Button(permissionsAllSet ? "Check permissions…" : "Set up permissions…") {
                DockPresence.enterWindowMode()
                PermissionWizard.present(server: server)
            }
            .buttonStyle(permissionsAllSet ? AnyButtonStyle(HostSecondaryButton())
                                           : AnyButtonStyle(HostPrimaryButton()))

            // macOS keys TCC grants to the app's code signature, so a rebuild or
            // an update can leave a STALE entry that is switched on but no longer
            // matches — the toggle looks right and injection still fails. Clearing
            // the entries forces a clean re-prompt. (See host-tcc-permission-resets.)
            Button("Reset permissions…") { server.resetPermissions() }
                .buttonStyle(HostSecondaryButton())
            hint("The fix when a grant looks enabled but input still doesn't work. Clears this app's entries so macOS asks again, then relaunches the host — the old answer is cached for the life of the process, so a restart is what makes the reset take.")

            // Directly under Reset, because the two are one workflow: reset,
            // re-grant in System Settings, then recheck.
            Button("Recheck permissions") {
                server.refreshAccessibility(); server.refreshScreenRecording()
            }.buttonStyle(HostSecondaryButton())

            rule

            // Paired phones. This section is the whole point of RT1 from the
            // user's side: it is where they can see which phones are allowed to
            // type on this Mac, and take that back.
            if paired.list.isEmpty {
                statusLine("No phones paired yet", symbol: "iphone.badge.play",
                           tint: HostDeck.sublegend)
            } else {
                ForEach(paired.list) { device in
                    HStack(spacing: 6) {
                        Image(systemName: device.platform == "ios" ? "iphone" : "candybarphone")
                            .font(.system(size: 11))
                            .foregroundStyle(HostDeck.statusGreen)
                        Text(device.name)
                            .font(.system(size: 12))
                            .foregroundStyle(HostDeck.legend)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button("Remove") { paired.forget(device.dev) }
                            .buttonStyle(HostSecondaryButton())
                    }
                }
            }

            HStack(spacing: 6) {
                Button("Pair a phone…") { PairingWindow.present() }
                    .buttonStyle(HostPrimaryButton())
                if !paired.list.isEmpty {
                    Button("Remove all") { paired.forgetAll() }
                        .buttonStyle(HostSecondaryButton())
                }
            }

            rule

            // Walk-away lock: a small status line so the user can
            // see the guard's state on the Mac itself.
            statusLine(walkAwayStatus, symbol: walkAwayIcon, tint: HostDeck.sublegend)

            // Casting (CASTING.md §9.2): while a session is active the menu shows
            // "Casting to <TV> — Stop" — the only stop affordance that survives a
            // dead phone.
            if let castTV = server.castTargetName {
                Button { server.stopCast() } label: {
                    Label("Casting to \(castTV) — Stop", systemImage: "tv.fill")
                }
                .buttonStyle(HostSecondaryButton())
            }

            Text("Last: \(server.lastEvent)")
                .font(.system(size: 11))
                .foregroundStyle(HostDeck.sublegend)
                .lineLimit(1)
                .truncationMode(.middle)

            rule

            // Full labels, wrapped in a grid — the old single HStack squeezed
            // four buttons into 280pt and truncated every one of them
            // ("Accessibi…", "Reche…").
            HStack(spacing: 6) {
                Button("Show activity") {
                    DockPresence.enterWindowMode(); openWindow(id: "activity")
                }.buttonStyle(HostSecondaryButton())
                Button("About") {
                    DockPresence.enterWindowMode(); openWindow(id: "about")
                }.buttonStyle(HostSecondaryButton())
                Button("Check for updates…") { HostUpdate.openDownloadPage() }
                    .buttonStyle(HostSecondaryButton())
            }
            // Start at login. Without it every reboot silently ended the
            // pairing, and with no Dock icon nothing said why — the phone just
            // stopped finding this Mac.
            Toggle("Start at login", isOn: Binding(
                get: { startsAtLogin },
                set: { want in if LoginItem.set(want) { startsAtLogin = want } }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundStyle(HostDeck.legend)

            HStack(spacing: 6) {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(HostSecondaryButton())
                Button("Uninstall…") { Uninstaller.run() }
                    .buttonStyle(HostSecondaryButton())
            }

            LANFootnote()
        }
        .onAppear {
            startsAtLogin = LoginItem.isEnabled
            paired.refresh()
            // Say something only when there IS something to say.
            Install.reviewStaleCopies(silentWhenClean: true)
        }
        .padding(14)
        // Wider than the old 280: every label now fits at full length instead of
        // being truncated to "Accessibi…" / "Reche…".
        .frame(width: 340, alignment: .leading)
        .background(HostFlowBackground())
    }

    /// One status row: glyph + text, wrapping rather than truncating.
    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(HostDeck.legend)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    /// Secondary explanatory copy. sublegend clears 6:1 on both appearances.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(HostDeck.sublegend)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private var rule: some View {
        Rectangle().fill(HostDeck.hairline).frame(height: 1)
    }

    /// "Walk-away lock: armed/locked/off" for the menu.
    private var walkAwayStatus: String {
        guard server.proximityArmed else { return "Walk-away lock: off" }
        switch server.proximityPhase {
        case .locked:  return "Walk-away lock: locked"
        case .leaving: return "Walk-away lock: leaving"
        case .inRange: return "Walk-away lock: armed (in range)"
        case .searching, .none: return "Walk-away lock: armed"
        }
    }

    private var walkAwayIcon: String {
        guard server.proximityArmed else { return "lock.open" }
        return server.proximityPhase == .locked ? "lock.fill" : "lock"
    }
}
