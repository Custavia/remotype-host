import Foundation

/// Lightweight append-only log for development/verification.
enum HostLog {
    static let path = "/tmp/remotypehost.log"
    private static let queue = DispatchQueue(label: "remotype.hostlog")

    /// Last 200 lines, observable — feeds the menu-bar "Activity" window so the
    /// host's signals (connect, disconnect, mode, TV, cast) are visible on
    /// demand without tailing the log file.
    static let live = HostLogLive()

    static func write(_ message: String) {
        DispatchQueue.main.async { live.append(message) }
        queue.async {
            let line = "\(Date()): \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}


/// Observable ring of recent activity lines (Activity window model).
final class HostLogLive: ObservableObject {
    @Published private(set) var lines: [String] = []
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    func append(_ message: String) {
        lines.append(Self.df.string(from: Date()) + "  " + message)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
}
