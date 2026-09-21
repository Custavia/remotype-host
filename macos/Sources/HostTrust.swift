import SwiftUI

/// The trust surface — the plain-language answers to the two questions a
/// careful user (rightly) asks before letting anything type on their Mac:
/// *why does it need these permissions*, and *does it phone home*.
///
/// One source of copy, shown the same way everywhere a permission or the
/// network posture appears: the first-run Welcome, the setup wizard, and the
/// menu-bar popover. The words do not get to drift between those places — the
/// reviewer who reads the wizard and then the menu must see the same promise.
enum HostTrust {

    // MARK: Permission explainers (layman terms, with what it does NOT do)

    /// The fuller "why", under the one-line headline. Says what macOS calls the
    /// permission, what Remotype uses it for, and — the part that earns trust —
    /// what it pointedly does not touch.
    static let accessibilityDetail =
        "macOS files “control the keyboard and mouse” under Accessibility. " +
        "Remotype Host uses it only to replay the keys and pointer moves your " +
        "phone sends. It never reads your screen, your typing, or what other " +
        "apps are doing."

    static let screenRecordingDetail =
        "macOS calls capturing any pixels “Screen Recording.” Remotype Host " +
        "turns it on only while you stream this Mac’s screen or sound to your " +
        "phone or a TV. Nothing is recorded or written to disk — the frames go " +
        "straight to your phone over your Wi-Fi and are dropped."

    /// Shown wherever a permission is explained: the user is never locked in.
    static let revokeNote =
        "You can turn either permission off any time — in System Settings, or " +
        "with Reset Permissions in the menu."

    // MARK: Network posture (the "no internet" promise, framed as a feature)

    static let lanHeadline = "Works entirely on your Wi-Fi"
    static let lanBody =
        "Remotype Host talks only to the phones and TVs on your network. " +
        "Nothing you do with it needs the internet, and nothing you type or " +
        "show ever leaves your network."
    /// The compact always-visible line — popover footer, wizard footer, tray tooltip.
    static let lanFootnote = "Wi-Fi: required · Internet: never"
}

/// The green "LAN" card — the positive statement of the network posture. Not an
/// offline/degraded look: needing no internet is the product's whole privacy
/// story, so it reads as a guarantee, not a limitation.
struct LANCard: View {
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(HostDeck.statusGreen.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: "wifi")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HostDeck.statusGreen)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(HostTrust.lanHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HostDeck.legend)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(HostDeck.statusGreen)
                }
                if !compact {
                    Text(HostTrust.lanBody)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(HostDeck.sublegend)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(HostDeck.statusGreen.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(HostDeck.statusGreen.opacity(0.22), lineWidth: 1)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(HostTrust.lanHeadline). \(HostTrust.lanFootnote)")
    }
}

/// The one-line always-visible footer. A green LAN pill and the plain promise,
/// small enough to sit at the bottom of the popover and the wizard without
/// asking for attention — but never absent.
struct LANFootnote: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(HostDeck.statusGreen)
            Text(HostTrust.lanFootnote)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HostDeck.sublegend)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HostTrust.lanFootnote)
    }
}
