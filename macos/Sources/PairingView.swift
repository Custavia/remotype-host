import AppKit
import SwiftUI

/// The pairing panel: the one moment where a human, at the computer, decides
/// that a particular phone is allowed to type on it.
///
/// It is a programmatic `NSWindow` rather than a SwiftUI `Window` scene for a
/// reason that only shows up in the field: the panel has to be openable from the
/// **network queue**, the instant a phone sends `pair.begin`. `openWindow` is a
/// SwiftUI Environment value, reachable only from inside a view body; the
/// handshake code has no view. Routing that through a notification and a hidden
/// observer view would work, but it would also mean the panel silently fails to
/// appear whenever that view has not been instantiated yet — which, in a
/// menu-bar app whose only guaranteed view is the tray glyph, is most of the
/// time.
@MainActor
enum PairingWindow {
    private static var window: NSWindow?

    /// Shows the panel, minting a fresh code if none is live. Safe to call
    /// repeatedly: a second call while a code is showing brings the same code
    /// forward rather than invalidating the one the user is mid-way through
    /// typing.
    static func present() {
        if PairingCode.shared.live == nil { PairingCode.shared.show() }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Pair a phone"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: PairingView())
        window = w
        DockPresence.enterWindowMode()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        DockPresence.leaveWindowModeIfIdle()
    }
}

struct PairingView: View {
    @ObservedObject private var pairing = PairingCode.shared
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                HostBrandMark(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair a phone")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HostDeck.legend)
                    // An instruction until it is done, then the result.
                    // Leaving "type this code on the phone" up after the phone
                    // has connected leaves the user looking for something still
                    // to do.
                    Text(pairing.connected.map { "Connected successfully — \($0)" }
                         ?? "Type this code on the phone, once.")
                        .font(.system(size: 14))
                        .foregroundStyle(pairing.connected == nil
                                         ? HostDeck.sublegend : HostDeck.statusGreen)
                }
            }

            if let paired = pairing.lastPaired {
                banner(symbol: "checkmark.seal.fill", tint: HostDeck.statusGreen,
                       title: "Paired with \(paired)",
                       body: "This phone can connect from now on without a code. You can remove it from the menu bar at any time.")
            } else if let status = pairing.status {
                // The ceremony ended on the phone's side. Say what happened
                // where the code used to be; "type this code" over a code that
                // is gone is worse than no window at all.
                banner(symbol: "xmark.circle", tint: HostDeck.statusAmber,
                       title: status,
                       body: "Nothing was paired. Tap this computer on the phone again, or show a new code.")
            } else if let code = pairing.code {
                codeCard(code)
            } else {
                banner(symbol: "clock.arrow.circlepath", tint: HostDeck.statusAmber,
                       title: "That code is no longer valid",
                       body: "Codes last ten minutes, and retire after three wrong tries. Show a new one and try again.")
            }

            // Said plainly, because the honest answer to "is this safe?" is the
            // reason the ceremony exists at all.
            VStack(alignment: .leading, spacing: 8) {
                row("Only someone who can see this screen can pair a phone.")
                row("After pairing, everything between phone and computer is encrypted.")
                row("A phone that is not paired cannot type, click, or read your clipboard.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(HostDeck.well))

            HStack(spacing: 10) {
                Button(pairing.code == nil ? "Show a new code" : "Show a different code") {
                    PairingCode.shared.show()
                }
                .buttonStyle(HostPrimaryButton())
                .frame(width: 210)

                // Always live. It used to be disabled until a phone had
                // completed the handshake — which left a window nobody could
                // dismiss when the phone never came, with a live code on
                // screen for ten minutes. Close means close; closing before a
                // phone paired retires the code (same rule as the Windows host).
                Button("Close") {
                    if pairing.connected == nil {
                        PairingCode.shared.burn(reason: "window closed before a phone paired")
                    }
                    PairingWindow.close()
                }
                    .buttonStyle(HostPrimaryButton())
                    .frame(width: 120)
                Spacer(minLength: 0)
            }
        }
        .padding(32)
        .frame(width: 460)
        .background(HostFlowBackground())
        .onReceive(tick) { now = $0 }
    }

    /// The code itself, grouped in threes and spaced generously. It is read off
    /// a screen and typed on a phone, so legibility beats density: a monospaced
    /// face keeps 0/O and 1/I distinguishable, and Crockford base32 has already
    /// removed the pairs that no font can save.
    private func codeCard(_ code: String) -> some View {
        VStack(spacing: 10) {
            Text(grouped(code))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(HostDeck.legend)
                .textSelection(.enabled)

            Text(countdown)
                .font(.system(size: 12))
                .foregroundStyle(HostDeck.sublegend)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(HostDeck.well))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HostDeck.accent.opacity(0.35), lineWidth: 1))
    }

    private func banner(symbol: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HostDeck.legend)
                Text(body)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(HostDeck.sublegend)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(HostDeck.well))
    }

    private func row(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(HostDeck.accent)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(HostDeck.legend)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var countdown: String {
        _ = now                                  // redraws once a second
        let s = PairingCode.shared.secondsRemaining
        guard s > 0 else { return "Expired" }
        return String(format: "Valid for %d:%02d", s / 60, s % 60)
    }

    /// Regroups the code in fours with generous spacing.
    ///
    /// It strips the separators FIRST, because `RT1.generateCode` already
    /// returns a hyphenated code — grouping the hyphenated form again produced
    /// "9SP8 -V69 -P1X ZY", which is both wrong and, on a screen someone is
    /// copying from, actively misleading.
    private func grouped(_ code: String) -> String {
        let bare = code.filter { $0.isLetter || $0.isNumber }
        return stride(from: 0, to: bare.count, by: 4).map { i -> String in
            let start = bare.index(bare.startIndex, offsetBy: i)
            let end = bare.index(start, offsetBy: min(4, bare.count - i))
            return String(bare[start..<end])
        }.joined(separator: "  ")
    }
}
