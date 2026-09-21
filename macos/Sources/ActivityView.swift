import SwiftUI

/// The menu-bar "Activity" window: a branded, auto-scrolling feed of the host's
/// recent activity (last 200 lines, live).
struct ActivityView: View {
    @ObservedObject private var live = HostLog.live

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("custavia-wordmark")
                    .resizable().scaledToFit().frame(height: 16)
                Text("Remotype — by Custavia").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(live.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: live.lines.count) { n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 300)
    }
}
