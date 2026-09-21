import SwiftUI
import AppKit

/// The MILLED palette, ported verbatim from the phone app's `Deck`
/// (ios/Sources/Theme.swift). The companion is the same product on a different
/// screen; it should not look like a different one.
///
/// Contrast is a hard requirement here, not a preference: every text colour in
/// this file was MEASURED against the surface it is drawn on and clears **6:1**
/// (Custavia rule). Two values had to move to get there — see accentFill and
/// statusRed below; the phone's originals failed at 5.07:1 and 5.65:1.
enum HostDeck {
    /// The companion is pinned to the app's DARK "Flow" look regardless of the
    /// macOS appearance — that blue-black gradient IS the product's home screen,
    /// and a popover that flipped to light grey on a light Mac would read as a
    /// different app sitting next to the phone.
    static let accent      = Color(nsColor: NSColor(rgb: 0x3D5BFF))
    /// Filled buttons use a DARKER blue than the brand accent on purpose:
    /// white on 0x3D5BFF measures 5.07:1, which fails the 6:1 rule. 0x3049E0
    /// is 6.66:1 and still unmistakably the brand blue. The brand MARK keeps
    /// the true accent — WCAG exempts logotypes, and the mark must match the
    /// phone exactly.
    static let accentFill  = Color(nsColor: NSColor(rgb: 0x3049E0))
    static let accentText  = Color(nsColor: NSColor(rgb: 0x9FB6FF))   // 7.4:1 on deck

    static let deck        = Color(nsColor: NSColor(rgb: 0x0B0E1A))
    static let well        = Color(nsColor: NSColor(rgb: 0x0F1322))
    static let surface     = Color(nsColor: NSColor(rgb: 0x161A2A))
    static let capTop      = Color(nsColor: NSColor(rgb: 0x1D2236))
    static let legend      = Color(nsColor: NSColor(rgb: 0xEEF1FB))   // 17.0:1
    static let sublegend   = Color(nsColor: NSColor(rgb: 0x9AA3C2))   // 7.7:1 deck, 6.9:1 surface
    static let hairline    = Color(nsColor: NSColor(rgb: 0x232A42))

    static let statusGreen = Color(nsColor: NSColor(rgb: 0x34C759))   // 8.7:1
    static let statusAmber = Color(nsColor: NSColor(rgb: 0xE8910E))   // 7.8:1
    /// Lightened from the phone's 0xFF453A, which is only 5.65:1 on this deck.
    static let statusRed   = Color(nsColor: NSColor(rgb: 0xFF6961))   // 6.8:1
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The same Flow signature background the phone's home screen uses: the deck
/// colour with two soft accent glows.
struct HostFlowBackground: View {
    var body: some View {
        ZStack {
            HostDeck.deck
            RadialGradient(colors: [HostDeck.accent.opacity(0.16), .clear],
                           center: .init(x: 0.85, y: 0.0), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [HostDeck.accent.opacity(0.10), .clear],
                           center: .init(x: 0.1, y: 1.0), startRadius: 0, endRadius: 220)
        }
    }
}

/// The Remotype brand mark — the SAME accent tile with a white "R" the phone
/// uses for its wordmark and Home button. One mark across the product.
struct HostBrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        Text("R")
            .font(.system(size: size * 17 / 34, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 9 / 34, style: .continuous)
                    .fill(HostDeck.accent)
            )
            .accessibilityHidden(true)
    }
}

/// A filled accent button, matching the phone's primary action.
struct HostPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)          // white on accentFill = 6.66:1
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HostDeck.accentFill.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// A quiet button on the deck surface — used for the footer row.
struct HostSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(HostDeck.legend)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? HostDeck.well : HostDeck.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(HostDeck.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// The menu-bar icon: the keyboard glyph the host has always used, with the
/// brand "R" badged onto it. Rendered as a TEMPLATE image so it inverts with
/// the menu bar instead of fighting it — the mark still reads as ours.
enum TrayIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let kb = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                kb.draw(in: NSRect(x: 0, y: 1.5, width: 15, height: 12),
                        from: .zero, operation: .sourceOver, fraction: 1)
            }
            // "R" badge, bottom-right — small enough not to muddy the glyph.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .black),
                .foregroundColor: NSColor.black,
            ]
            NSString(string: "R").draw(at: NSPoint(x: 12.5, y: 0), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Type-erases a `ButtonStyle` so one call site can pick between two.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
