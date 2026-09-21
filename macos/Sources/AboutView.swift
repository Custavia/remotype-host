import SwiftUI

/// Custavia-branded About window for the Mac host (opened from the menu-bar
/// "About" item). Follows the system appearance — cream in light, warm ink in
/// dark — matching the Custavia brand wallpapers.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme

    /// Human release date of this build. Bump per release.
    private static let releaseDate = "September 2026"
    private static let supportEmail = "support.remotype@custavia.com"
    private static let productURL = URL(string: "https://remotype.custavia.com")!

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "Version \(v)"
    }

    /// Which slice of the universal binary is actually executing.
    ///
    /// `#if arch(...)` is evaluated per slice, so the compiled answer is always
    /// the true one — an x86_64 build cannot report "Apple Silicon". The Rosetta
    /// check matters separately: an Intel slice running translated on an Apple
    /// Silicon Mac works, but slower and for no reason, and it is the one state
    /// worth naming so it can be fixed by reinstalling.
    private var architecture: String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return isTranslated ? "Intel (x86-64) — running under Rosetta" : "Intel (x86-64)"
        #else
        return "Unknown architecture"
        #endif
    }

    private var isTranslated: Bool {
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &flag, &size, nil, 0) == 0 else { return false }
        return flag == 1
    }

    private var wordmark: NSImage? {
        let name = scheme == .dark ? "custavia-wordmark-dark" : "custavia-wordmark"
        return Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    // Brand grounds (match the wallpaper base colours).
    private var bg: Color { scheme == .dark ? Color(red: 0.075, green: 0.071, blue: 0.055)
                                            : Color(red: 0.929, green: 0.929, blue: 0.914) }
    private var ink: Color { scheme == .dark ? Color(red: 0.91, green: 0.90, blue: 0.87)
                                            : Color(red: 0.09, green: 0.11, blue: 0.10) }
    /// 0.72, not 0.58: the lighter tint measured 4.17:1 on the light ground,
    /// below Custavia's 6:1 floor. At 0.72 it is 6.6:1 light / 8.1:1 dark.
    private var muted: Color { ink.opacity(0.72) }
    /// Link tint. The light value is darkened from the brand seed (0.23/0.39/0.33
    /// measured 5.74:1 — a hair under the 6:1 floor); this one is 7.2:1.
    private var seed: Color { scheme == .dark ? Color(red: 0.66, green: 0.81, blue: 0.74)
                                             : Color(red: 0.18, green: 0.33, blue: 0.28) }

    var body: some View {
        VStack(spacing: 18) {
            if let wm = wordmark {
                Image(nsImage: wm).resizable().scaledToFit().frame(height: 48)
                    .accessibilityLabel("Custavia")
            } else {
                Text("Custavia").font(.system(size: 24, weight: .semibold, design: .serif))
            }

            VStack(spacing: 3) {
                Text("Remotype Host").font(.system(size: 17, weight: .semibold))
                Text(version).font(.system(size: 12)).foregroundStyle(muted)
                Text("Released \(Self.releaseDate)").font(.system(size: 12)).foregroundStyle(muted)
                Text(architecture).font(.system(size: 12)).foregroundStyle(muted)
            }

            Rectangle().fill(ink.opacity(0.12)).frame(width: 210, height: 1)

            VStack(spacing: 7) {
                HStack(spacing: 4) {
                    Text("Developed by").font(.system(size: 13, weight: .medium))
                    // The label is styled, not the Link: the VStack's
                    // .foregroundStyle(ink) wins over .tint() on a Link, so a
                    // tinted link rendered as plain black body text with no hint
                    // that it was tappable. Underline too — colour alone is not
                    // a sufficient affordance (WCAG 1.4.1).
                    Link(destination: Self.productURL) {
                        Text("Custavia")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(seed)
                            .underline()
                    }
                }
                Text("Contact us at:").font(.system(size: 12)).foregroundStyle(muted)
                Link(destination: URL(string: "mailto:\(Self.supportEmail)")!) {
                    Text(Self.supportEmail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(seed)
                        .underline()
                }
            }
        }
        .foregroundStyle(ink)
        .padding(30)
        .frame(width: 340, height: 320)
        .background(bg)
    }
}
