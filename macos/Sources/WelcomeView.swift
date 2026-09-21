import SwiftUI

/// FIRST RUN — the thirty seconds where a menu-bar app loses people.
///
/// `LSUIElement` means no Dock icon and no window, so the honest description of
/// the old first run is: the user drags the app over, double-clicks it, and
/// **nothing visibly happens**. There is a new glyph in the menu bar, but nobody
/// told them to look there. And the host needs up to three permissions —
/// Accessibility, Screen Recording, Local Network — every one of which can only
/// be requested from inside the panel they have not found.
///
/// So the real first run was: quarantine dialog → apparent nothing → hunt for a
/// menu-bar icon → grant Accessibility → relaunch → grant Screen Recording →
/// relaunch. That is where a paying user gives up and emails instead.
///
/// This window appears once, says where the app lives, and puts the permissions
/// in front of the user in the order the app actually needs them — with the
/// current state of each, so granting one and coming back shows progress rather
/// than the same undifferentiated list.
struct WelcomeView: View {
    @ObservedObject var server: Server
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                HostBrandMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remotype Host is running")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HostDeck.legend)
                    Text("It lives in your menu bar, not the Dock.")
                        .font(.system(size: 14))
                        .foregroundStyle(HostDeck.sublegend)
                }
            }

            // The single most useful sentence in the window: WHERE to look. A
            // menu-bar app that is never found is an app that was never installed.
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HostDeck.accent)
                Text("Look for the keyboard icon at the top-right of your screen. Click it any time for status, settings, or to quit.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(HostDeck.legend)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(HostDeck.well))

            VStack(alignment: .leading, spacing: 6) {
                Text("Two permissions to allow")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HostDeck.legend)
                Text("macOS asks for these itself — Remotype never sees them until you say yes. We'll walk you through both, one at a time.")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(HostDeck.sublegend)
                    .fixedSize(horizontal: false, vertical: true)
                Text(HostTrust.revokeNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(HostDeck.sublegend.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                permissionRow(
                    title: "Accessibility",
                    why: "Lets your phone type and move the pointer.",
                    detail: "Only replays what your phone sends — never reads your screen or typing.",
                    granted: server.accessibilityTrusted)

                permissionRow(
                    title: "Screen Recording",
                    why: "Only to see this Mac\u{2019}s screen and hear its sound on your phone.",
                    detail: "Optional. Nothing is recorded or saved — skip it for just keyboard and trackpad.",
                    granted: server.screenRecordingTrusted)
            }

            LANCard()

            HStack(spacing: 10) {
                // One button, not one per row. The old window put an "Allow…"
                // on each and left the user to work out the order, whether the
                // first one took, and what to do about the restart the second
                // one needs. That is the wizard's job now.
                Button(allGranted ? "Check permissions" : "Set them up") {
                    dismiss()
                    PermissionWizard.present(server: server)
                }
                .buttonStyle(HostPrimaryButton())
                .frame(width: 190)

                Button("Later") { dismiss() }
                    .buttonStyle(HostSecondaryButton())
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(32)
        .frame(width: 500)
        .background(HostDeck.deck)
    }

    private var allGranted: Bool {
        server.accessibilityTrusted && server.screenRecordingTrusted
    }

    /// Status only — the row no longer carries its own button. See the note on
    /// the single "Set them up" action above.
    private func permissionRow(title: String, why: String, detail: String, granted: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.seal.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? HostDeck.statusGreen : HostDeck.sublegend)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HostDeck.legend)
                Text(why).font(.system(size: 13)).foregroundStyle(HostDeck.sublegend)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(HostDeck.sublegend.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(granted ? "Allowed" : "Not yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(granted ? HostDeck.statusGreen : HostDeck.sublegend)
        }
    }
}
