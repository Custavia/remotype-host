import AppKit
import Foundation

/// Clipboard FILE transfer (CLIPBOARD.md phase 2) — the vault's binary half,
/// Mac side. Mirrors the Windows host:
///
///   Push (phone → Mac): clip.file.push {id,name,size} → clip.file.ok → chunks
///     {id,seq,data(b64)} → clip.file.done → the file lands in
///     ~/Downloads/Remotype AND on the pasteboard as a real file URL, so ⌘V in
///     Finder pastes it. Reply: clip.file.saved {id,path}.
///   Pull (Mac → phone): clip.file.pull {id} → first file URL on the pasteboard
///     within the 32 MB cap: clip.file.meta + chunks + clip.file.done, else
///     clip.file.err {id, reason: nofile|toolarge}.
final class ClipFile {
    static let maxBytes = 32 << 20
    static let chunk = 48 << 10

    // Single in-flight push (the phone serializes transfers).
    private var id = ""
    private var name = ""
    private var size = 0
    private var data = Data()

    /// Where pushed files land. Created on demand.
    static func downloadDir() -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remotype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func dedupe(_ dir: URL, _ name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            url = dir.appendingPathComponent(n)
            i += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    // ---- push ----------------------------------------------------------------

    func begin(id: String, name: String, size: Int, reply: ([String: Any]) -> Void) {
        guard size > 0, size <= Self.maxBytes else {
            reply(["t": "clip.file.err", "id": id, "reason": "toolarge"]); return
        }
        self.id = id
        // Base-name only: a hostile name must not escape the download folder.
        self.name = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        if self.name.isEmpty { self.name = "clipboard.bin" }
        self.size = size
        self.data = Data(capacity: size)
        reply(["t": "clip.file.ok", "id": id])
    }

    func chunk(id: String, b64: String, reply: ([String: Any]) -> Void) {
        guard id == self.id, let raw = Data(base64Encoded: b64),
              data.count + raw.count <= size else {
            if id == self.id { self.id = "" ; reply(["t": "clip.file.err", "id": id, "reason": "corrupt"]) }
            return
        }
        data.append(raw)
    }

    func done(id: String, reply: ([String: Any]) -> Void) {
        guard id == self.id else { return }
        let url = Self.dedupe(Self.downloadDir(), name)
        do {
            try data.write(to: url)
        } catch {
            reply(["t": "clip.file.err", "id": id, "reason": "write"]); self.id = ""; return
        }
        // ⌘V in Finder now pastes the file itself.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        HostLog.write("clipboard file saved: \(url.lastPathComponent) (\(data.count) bytes)")
        reply(["t": "clip.file.saved", "id": id, "path": url.path])
        self.id = ""; self.data = Data()
    }

    // ---- pull ----------------------------------------------------------------

    func pull(id: String, reply: ([String: Any]) -> Void) {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else {
            reply(["t": "clip.file.err", "id": id, "reason": "nofile"]); return
        }
        guard let bytes = try? Data(contentsOf: url), bytes.count <= Self.maxBytes else {
            reply(["t": "clip.file.err", "id": id, "reason": "toolarge"]); return
        }
        reply(["t": "clip.file.meta", "id": id, "name": url.lastPathComponent, "size": bytes.count])
        var off = 0
        var seq = 0
        while off < bytes.count {
            let end = min(off + Self.chunk, bytes.count)
            reply(["t": "clip.file.chunk", "id": id, "seq": seq,
                   "data": bytes.subdata(in: off..<end).base64EncodedString()])
            off = end; seq += 1
        }
        reply(["t": "clip.file.done", "id": id])
        HostLog.write("clipboard file sent: \(url.lastPathComponent) (\(bytes.count) bytes)")
    }
}
