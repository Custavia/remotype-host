import AppKit

/// THE DOCK ICON, ONLY WHEN THERE IS A WINDOW.
///
/// The host is a menu-bar app (`LSUIElement`), which is right for something that
/// spends its life in the background — but it has real windows too (About,
/// Activity, Welcome), and an accessory app's windows are second-class citizens:
/// no Dock tile to click back to, nothing in ⌘-Tab, and a window that can end up
/// behind whatever the user is actually doing with no way to raise it.
///
/// So the policy follows the windows, the way Tailscale and 1Password do it:
///
///  - no windows → `.accessory`: menu-bar glyph only, no Dock tile, out of ⌘-Tab
///  - a window opens → `.regular`: Dock tile appears, ⌘-Tab works, the window can
///    be raised and focused like any normal app's
///  - the last window closes → back to `.accessory`
///
/// The switch is what makes an accessory app's windows behave. Without it,
/// `openWindow` on a `.accessory` app produces a window that cannot reliably be
/// brought to the front, which is the "I clicked About and nothing happened"
/// class of bug — the window was there, behind Safari, unreachable.
enum DockPresence {

    /// Windows we own and count. The MenuBarExtra's popover is a window too, and
    /// counting it would keep the Dock tile alive for as long as the menu is
    /// open — so membership is explicit rather than "anything visible".
    private static let ownedIDs: Set<String> = ["about", "activity", "welcome"]

    private static var observing = false

    /// Show the Dock tile and bring the app forward. Call BEFORE `openWindow`:
    /// the policy change has to be in effect when the window is created, or the
    /// window is born accessory and stays unfocusable.
    static func enterWindowMode() {
        startObservingIfNeeded()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drop back to menu-bar-only once nothing of ours is on screen.
    static func leaveWindowModeIfIdle() {
        guard !hasOwnedWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private static var hasOwnedWindow: Bool {
        NSApp.windows.contains { win in
            guard win.isVisible, let id = win.identifier?.rawValue else { return false }
            // SwiftUI decorates the identifier (e.g. "about-AppWindow-1"), so match
            // on the prefix rather than equality.
            return ownedIDs.contains { id == $0 || id.hasPrefix("\($0)-") }
        }
    }

    private static func startObservingIfNeeded() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            // willClose fires BEFORE the window leaves NSApp.windows, so the count
            // is still stale here. Re-check on the next runloop pass.
            DispatchQueue.main.async { leaveWindowModeIfIdle() }
        }
    }
}
