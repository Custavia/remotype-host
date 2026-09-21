import AppKit
import SwiftUI

/// Renders the host's windows offscreen, for looking at.
///
/// See the note at its call site: every window in this app sits behind a
/// permission grant, a paired phone, or a first launch, on a Mac that must be
/// awake and unlocked. Without this, changing one and checking it are different
/// days' work.
@MainActor
enum UISnapshot {
    static func writeAll(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A Server that is constructed but never `start()`ed: no listener, no
        // Bonjour, no capture. It exists so the views have their real state.
        let server = Server()
        server.refreshAccessibility()
        server.refreshScreenRecording()

        // Both states of both steps, plus the summary. The PENDING state is the
        // one every user meets and the one nobody on the team ever sees, because
        // by the time you are testing, your own Mac has already granted them.
        let pending = Server()
        pending.accessibilityTrusted = false
        pending.screenRecordingTrusted = false
        pending.accessibilityGranted = false
        pending.screenGranted = false

        // granted-but-not-live: the switch is on, only a restart is left. Every
        // reinstall-over-a-live-grant lands here, so it gets its own snapshot.
        let restartPending = Server()
        restartPending.accessibilityTrusted = false
        restartPending.screenRecordingTrusted = false
        restartPending.accessibilityGranted = true
        restartPending.screenGranted = true

        write(PermissionWizardView(server: pending), "wizard-1-accessibility", to: dir)
        write(PermissionWizardView(server: pending, startAt: 1), "wizard-2-screen", to: dir)
        write(PermissionWizardView(server: server), "wizard-1-granted", to: dir)
        write(PermissionWizardView(server: pending, startAt: 2), "wizard-3-summary", to: dir)
        write(PermissionWizardView(server: restartPending, startAt: 0), "wizard-1-restart-pending", to: dir)
        write(PermissionWizardView(server: restartPending, startAt: 2), "wizard-3-restart-pending", to: dir)
        write(WelcomeView(server: pending), "welcome", to: dir)
        write(PairingView(), "pairing", to: dir)
        write(AboutView(), "about", to: dir)

        // The illustration on its own, big, since it is the part that has to
        // read at a glance.
        write(SettingsToggleIllustration(appName: "Remotype Host", paneTitle: "Accessibility", granted: false)
                .frame(width: 520, height: 240)
                .background(HostDeck.deck),
              "illustration", to: dir)
        write(SettingsToggleIllustration(appName: "Remotype Host", paneTitle: "Accessibility", granted: true)
                .frame(width: 520, height: 240)
                .background(HostDeck.deck),
              "illustration-granted", to: dir)

        FileHandle.standardOutput.write(Data("wrote snapshots to \(dir.path)\n".utf8))
    }

    private static func write<V: View>(_ view: V, _ name: String, to dir: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
