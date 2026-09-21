import Foundation
import Network
import Security
import CryptoKit

/// The Tier-B0 browser cast server (CASTING.md §6.5 / §7.0). A second NWListener,
/// bound to the chosen LAN interface (§6.7) on a fixed port (ephemeral fallback),
/// that serves — at the per-session token path — (a) the self-contained receiver
/// page and (b) a `multipart/x-mixed-replace` MJPEG stream of the full display.
///
/// The full-display CaptureController feeds `broadcast(_:)`; one JPEG stream is
/// fanned out to every open browser. Each viewer has its OWN newest-wins /
/// one-in-flight / 1 s-stuck-safety-net backpressure (copied from the Server's
/// TV-frame pump) so a slow TV browser never backs up capture or other viewers.
///
/// THREADING: one serial queue owns the listener, every connection, all viewer
/// state, and `broadcast`. `viewerCount`/`fps` are read off-queue by the session
/// (informational, like CaptureController.isManualFollow) — a benign stale read.
final class CastHTTPServer {

    /// Fixed browser-cast port (§8.4 URL). Falls back to an OS-assigned port if
    /// it is busy — the phone shows whatever port the URL carries either way.
    static let fixedPort: UInt16 = 50809
    /// How long after teardown the listener keeps serving 410 Gone — comfortably
    /// longer than the receiver's `/ping` interval so even a throttled/backgrounded
    /// tab catches the "Cast ended" before the port closes.
    static let graceSeconds: TimeInterval = 12
    /// A viewer whose current frame send hasn't been accepted by the network stack
    /// within this window is treated as wedged and dropped (not force-fed more).
    static let wedgeSeconds: TimeInterval = 6

    private let ip: String
    private let token: String
    private let code: String
    private let audioEnabled: Bool
    private let html: Data
    private let queue = DispatchQueue(label: "remotype.casthttp")

    private var listener: NWListener?
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    /// The most recent framed MJPEG chunk, sent to a browser the instant it
    /// connects so the first paint isn't delayed by up to a frame interval.
    private var lastChunk: Data?
    /// Once torn down, every `/c/…` request answers 410 (a brief grace so an
    /// open receiver's next `/ping` shows "Cast ended" before the socket closes).
    private var invalidated = false
    private var frameTimes: [CFAbsoluteTime] = []
    private var startCompletion: ((UInt16?) -> Void)?
    private var didComplete = false

    /// Live viewer count / delivered fps — read from the session's .main queue.
    private(set) var viewerCount = 0
    private(set) var fps = 0

    /// Fired (on the server queue) whenever a viewer joins or leaves; the Server
    /// marshals it to .main to drive waiting_viewer⇄casting(viewers:N).
    var onViewersChanged: ((Int) -> Void)?

    /// Fired when the first audio WebSocket connects (true) / the last leaves
    /// (false); the Server lazily starts/stops the computer-audio capture.
    var onAudioWanted: ((Bool) -> Void)?

    private var audioViewers: [ObjectIdentifier: AudioViewer] = [:]

    /// One open browser connection to the MJPEG stream. All fields are touched
    /// only on the server queue.
    private final class Viewer {
        let conn: NWConnection
        var pending: Data?
        var inFlight = false
        var gen = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }

    /// One open audio WebSocket; a small ordered FIFO (not newest-wins — audio
    /// must stay continuous). Touched only on the server queue.
    private final class AudioViewer {
        let conn: NWConnection
        var queue: [Data] = []
        var inFlight = false
        init(_ conn: NWConnection) { self.conn = conn }
    }

    init(ip: String, token: String, code: String, audioEnabled: Bool, html: Data) {
        self.ip = ip
        self.token = token
        self.code = code
        self.audioEnabled = audioEnabled
        self.html = html
    }

    deinit {
        listener?.cancel()
        for v in viewers.values { v.conn.cancel() }
        for av in audioViewers.values { av.conn.cancel() }
    }

    // MARK: Credentials

    /// A 256-bit base64url session token (§14.2) + a 4-digit human pairing code.
    /// Value of one `key` in an `a=1&b=2` query string (percent-decoded), or nil.
    static func queryValue(_ query: String, _ key: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first.map(String.init) == key {
                let raw = kv.count > 1 ? String(kv[1]) : ""
                return raw.removingPercentEncoding ?? raw
            }
        }
        return nil
    }

    /// Length-independent, byte-independent equality for the session token.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<x.count { diff |= Int(x[i]) ^ Int(y[i < y.count ? i : 0]) }
        return diff == 0
    }

    static func newCredentials() -> (token: String, code: String) {
        var tokenBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
        let token = Data(tokenBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var codeBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, codeBytes.count, &codeBytes)
        let code = codeBytes.map { String($0 % 10) }.joined()
        return (token, code)
    }

    // MARK: Lifecycle

    /// Bind + start. `completion` gets the actual bound port (nil on total
    /// failure) so the caller can build the `cast.ready` URL. Called once.
    func start(completion: @escaping (UInt16?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.startCompletion = completion
            self.startListener(port: NWEndpoint.Port(rawValue: CastHTTPServer.fixedPort) ?? .any)
        }
    }

    private func startListener(port: NWEndpoint.Port, attempt: Int = 0) {
        guard let host = IPv4Address(ip) else { finishStart(nil); return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to the chosen LAN interface ONLY (§6.7 / §14.1) — not wildcard.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(host), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            retryBind(port: port, attempt: attempt)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            self?.queue.async {
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.finishStart(listener.port?.rawValue ?? CastHTTPServer.fixedPort)
                case .failed:
                    listener.cancel()
                    self.retryBind(port: port, attempt: attempt)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// A prior session reclaiming the same fixed port may still be releasing it —
    /// retry the fixed port briefly before falling back to an ephemeral one, so
    /// the URL stays stable (browser history/autocomplete) across restarts.
    private func retryBind(port: NWEndpoint.Port, attempt: Int) {
        if port != .any && attempt < 6 {
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.startListener(port: port, attempt: attempt + 1)
            }
        } else if port != .any {
            startListener(port: .any)
        } else {
            finishStart(nil)
        }
    }

    /// Cancel the listener + viewers immediately (skip the 410 grace) so a new
    /// session can reclaim the fixed port right away. The just-started session
    /// will 410 any straggler viewer of this one (different token) → "Cast ended".
    func forceClose() {
        queue.async {
            self.invalidated = true
            for v in self.viewers.values { v.conn.cancel() }
            self.viewers.removeAll()
            for av in self.audioViewers.values { av.conn.cancel() }
            self.audioViewers.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finishStart(_ port: UInt16?) {
        guard !didComplete else { return }
        didComplete = true
        if let port { HostLog.write("cast browser server on port \(port)") }
        let c = startCompletion
        startCompletion = nil
        c?(port)
    }

    /// Invalidate the token + close (teardown, §10.6 step 2). Keeps the listener
    /// alive for a grace window so an open receiver's `/ping` (and a stream
    /// reload) return 410 Gone → "Cast ended" rather than connection-refused →
    /// a forever "Reconnecting…" spinner.
    ///
    /// STRONG `self` captures here are load-bearing: the caller drops its only
    /// reference (`browserHTTP = nil`) the instant it calls `stop()`, so if these
    /// blocks captured `self` weakly the object would dealloc immediately, `deinit`
    /// would cancel the listener at once, and the grace would never run.
    func stop() {
        queue.async {
            guard !self.invalidated else { return }
            self.invalidated = true                       // /ping + /stream now 410
            for v in self.viewers.values { v.conn.cancel() }
            self.viewers.removeAll()
            for av in self.audioViewers.values { av.conn.cancel() }
            self.audioViewers.removeAll()
            self.viewerCount = 0
            self.lastChunk = nil
            self.fps = 0
            self.queue.asyncAfter(deadline: .now() + CastHTTPServer.graceSeconds) {
                self.listener?.cancel()
                self.listener = nil
                // self releases when this block returns → deinit (idempotent).
            }
        }
    }

    // MARK: Frame fan-out

    /// Fed by the full-display CaptureController on its own queue; hops onto the
    /// server queue and pushes the frame to every viewer, newest-wins.
    func broadcast(_ jpeg: Data) {
        queue.async { [weak self] in
            guard let self, !self.invalidated else { return }
            let chunk = self.frameChunk(jpeg)
            self.lastChunk = chunk
            self.recordFrame()
            for v in self.viewers.values {
                v.pending = chunk
                self.pump(v)
            }
        }
    }

    private func frameChunk(_ jpeg: Data) -> Data {
        var d = Data("--rmtp\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        d.append(jpeg)
        d.append(contentsOf: [0x0D, 0x0A])   // trailing CRLF
        return d
    }

    private func recordFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1.0 }
        fps = frameTimes.count
    }

    /// Per-viewer backpressure: at most one send in flight, intermediate frames
    /// dropped (newest-wins via `pending`). `.contentProcessed` is the real
    /// TCP-backpressure signal (fires when the stack accepts the bytes), so a
    /// merely-slow viewer is throttled correctly without piling frames up. A
    /// viewer whose send hasn't been accepted in `wedgeSeconds` is genuinely stuck
    /// — DROP it (cancel), rather than force-queuing another frame behind the
    /// stalled one; one dead TV browser must not back up capture or its peers.
    private func pump(_ v: Viewer) {
        guard !v.inFlight, let data = v.pending else { return }
        v.pending = nil
        v.inFlight = true
        v.gen += 1
        let gen = v.gen
        v.conn.send(content: data, completion: .contentProcessed { [weak self, weak v] _ in
            self?.queue.async {
                guard let self, let v, v.gen == gen else { return }
                v.inFlight = false
                self.pump(v)
            }
        })
        queue.asyncAfter(deadline: .now() + CastHTTPServer.wedgeSeconds) { [weak self, weak v] in
            guard let self, let v, v.inFlight, v.gen == gen else { return }
            self.removeViewer(v.conn)   // send un-accepted for wedgeSeconds → dead
            v.conn.cancel()
        }
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                self.removeViewer(conn)
                self.removeAudioViewer(conn)
            default: break
            }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Read the full header block (up to the blank line), parse the request line
    /// + headers, route. Headers are needed for the `/audio` WebSocket upgrade.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = self.indexOfHeaderEnd(buf) {
                let text = String(decoding: buf[buf.startIndex..<end], as: UTF8.self)
                let lines = text.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                var headers: [String: String] = [:]
                for l in lines.dropFirst() {
                    guard let c = l.firstIndex(of: ":") else { continue }
                    let k = l[l.startIndex..<c].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                    headers[k] = v
                }
                self.route(conn, requestLine: requestLine, headers: headers)
                return
            }
            if isComplete || error != nil || buf.count > 16384 { conn.cancel(); return }
            self.readRequest(conn, buffer: buf)
        }
    }

    /// Index just past the `\r\n\r\n` that ends the header block, or nil.
    private func indexOfHeaderEnd(_ data: Data) -> Data.Index? {
        guard data.count >= 4 else { return nil }
        var i = data.startIndex
        let last = data.index(data.endIndex, offsetBy: -3)
        while i < last {
            if data[i] == 0x0D,
               data[data.index(i, offsetBy: 1)] == 0x0A,
               data[data.index(i, offsetBy: 2)] == 0x0D,
               data[data.index(i, offsetBy: 3)] == 0x0A {
                return data.index(i, offsetBy: 4)
            }
            i = data.index(after: i)
        }
        return nil
    }

    private func route(_ conn: NWConnection, requestLine: String, headers: [String: String]) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { writeClose(conn, "400 Bad Request", "text/plain", Data("bad".utf8), head: false); return }
        let method = String(parts[0])
        let head = (method == "HEAD")
        guard method == "GET" || head else {
            writeClose(conn, "405 Method Not Allowed", "text/plain", Data("no".utf8), head: false); return
        }
        // Separate path and query (the receiver appends ?r=… as a cache-buster;
        // the code-entry landing passes ?code=…).
        let rawTarget = String(parts[1])
        let split = rawTarget.split(separator: "?", maxSplits: 1)
        let path = split.first.map(String.init) ?? rawTarget
        let query = split.count > 1 ? String(split[1]) : ""

        // Root landing = the typeable path (the "or open <host:port>" line). A
        // 256-bit token is untypeable, so the human path in is the 4-digit code:
        // bare "/" shows the code-entry page; a correct "?code=NNNN" serves the
        // receiver (which then loads the token-scoped stream). This is what makes
        // typing the host:port actually work instead of 404ing.
        if path == "/" || path.isEmpty {
            if invalidated {
                writeClose(conn, "410 Gone", "text/html; charset=utf-8",
                           Data(BrowserReceiver.codeEntryPage(wrong: false, ended: true).utf8),
                           head: head, cacheControl: "no-cache"); return
            }
            let entered = CastHTTPServer.queryValue(query, "code")
            if let entered, CastHTTPServer.constantTimeEqual(entered, code) {
                // Redirect to the canonical token URL so the address bar (and
                // browser history / autocomplete) holds the real, reusable link.
                writeRedirect(conn, to: "/c/\(token)")
            } else {
                writeClose(conn, "200 OK", "text/html; charset=utf-8",
                           Data(BrowserReceiver.codeEntryPage(wrong: entered != nil, ended: false).utf8),
                           head: head, cacheControl: "no-cache")
            }
            return
        }
        guard path.hasPrefix("/c/") else {
            writeClose(conn, "404 Not Found", "text/plain", Data("not found".utf8), head: head); return
        }
        let rest = String(path.dropFirst(3))
        let tok: String, suffix: String
        if let slash = rest.firstIndex(of: "/") {
            tok = String(rest[rest.startIndex..<slash])
            suffix = String(rest[slash...])
        } else {
            tok = rest
            suffix = ""
        }
        // Unknown / invalidated token → 410 Gone. The receiver's /ping poll reads
        // the STATUS (410) to show "Cast ended"; a human revisiting a dead link
        // from history gets the branded ended page instead of raw text. Constant-
        // time compare so request timing can't leak the token (defense-in-depth).
        guard !invalidated, CastHTTPServer.constantTimeEqual(tok, token) else {
            writeClose(conn, "410 Gone", "text/html; charset=utf-8",
                       Data(BrowserReceiver.codeEntryPage(wrong: false, ended: true).utf8),
                       head: head, cacheControl: "no-cache"); return
        }
        switch suffix {
        case "", "/":
            writeClose(conn, "200 OK", "text/html; charset=utf-8", html, head: head, cacheControl: "no-cache")
        case "/ping":
            writeClose(conn, "200 OK", "text/plain; charset=utf-8", Data("ok".utf8), head: head, cacheControl: "no-cache")
        case "/stream":
            if head { writeClose(conn, "200 OK", "multipart/x-mixed-replace; boundary=rmtp", Data(), head: true, cacheControl: "no-cache") }
            else { serveStream(conn) }
        case "/audio":
            guard audioEnabled,
                  headers["upgrade"]?.lowercased().contains("websocket") == true,
                  let key = headers["sec-websocket-key"] else {
                writeClose(conn, "404 Not Found", "text/plain", Data("not found".utf8), head: head); return
            }
            acceptAudioSocket(conn, key: key)
        default:
            writeClose(conn, "404 Not Found", "text/plain", Data("not found".utf8), head: head)
        }
    }

    // MARK: Audio WebSocket (§6.2 — computer audio as 48 kHz mono Int16 PCM)

    private func acceptAudioSocket(_ conn: NWConnection, key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
                   "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] err in
            guard err == nil else { conn.cancel(); return }
            self?.queue.async {
                guard let self, !self.invalidated else { conn.cancel(); return }
                let av = AudioViewer(conn)
                self.audioViewers[ObjectIdentifier(conn)] = av
                if self.audioViewers.count == 1 { self.onAudioWanted?(true) }   // lazy-start capture
            }
        })
    }

    /// Feed one PCM chunk (48 kHz mono Int16 LE) to every audio WebSocket, wrapped
    /// as an unmasked binary frame. Ordered per viewer; a viewer that backs up past
    /// ~300 ms drops its oldest frames (a brief glitch beats unbounded latency).
    func broadcastAudio(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, !self.invalidated, !self.audioViewers.isEmpty else { return }
            let frame = CastHTTPServer.wsBinaryFrame(pcm)
            for av in self.audioViewers.values {
                av.queue.append(frame)
                while av.queue.count > 15 { av.queue.removeFirst() }
                self.pumpAudio(av)
            }
        }
    }

    private func pumpAudio(_ av: AudioViewer) {
        guard !av.inFlight, !av.queue.isEmpty else { return }
        let frame = av.queue.removeFirst()
        av.inFlight = true
        av.conn.send(content: frame, completion: .contentProcessed { [weak self, weak av] _ in
            self?.queue.async {
                guard let self, let av else { return }
                av.inFlight = false
                self.pumpAudio(av)
            }
        })
    }

    private func removeAudioViewer(_ conn: NWConnection) {
        if audioViewers.removeValue(forKey: ObjectIdentifier(conn)) != nil,
           audioViewers.isEmpty { onAudioWanted?(false) }   // last listener left → stop capture
    }

    /// A WebSocket server→client binary frame (FIN + opcode 0x2, unmasked).
    private static func wsBinaryFrame(_ payload: Data) -> Data {
        var f = Data([0x82])
        let n = payload.count
        if n <= 125 {
            f.append(UInt8(n))
        } else if n <= 0xFFFF {
            f.append(126)
            f.append(UInt8((n >> 8) & 0xFF)); f.append(UInt8(n & 0xFF))
        } else {
            f.append(127)
            for s in stride(from: 56, through: 0, by: -8) { f.append(UInt8((n >> s) & 0xFF)) }
        }
        f.append(payload)
        return f
    }

    private func writeRedirect(_ conn: NWConnection, to location: String) {
        let s = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n" +
                "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func writeClose(_ conn: NWConnection, _ status: String, _ contentType: String,
                            _ body: Data, head: Bool, cacheControl: String? = nil) {
        var s = "HTTP/1.1 \(status)\r\n"
        s += "Content-Type: \(contentType)\r\n"
        s += "Content-Length: \(body.count)\r\n"
        if let cacheControl { s += "Cache-Control: \(cacheControl)\r\n" }
        s += "Connection: close\r\n\r\n"
        var out = Data(s.utf8)
        if !head { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveStream(_ conn: NWConnection) {
        let hdr = "HTTP/1.1 200 OK\r\n" +
                  "Content-Type: multipart/x-mixed-replace; boundary=rmtp\r\n" +
                  "Cache-Control: no-cache\r\n" +
                  "Pragma: no-cache\r\n" +
                  "Connection: close\r\n\r\n"
        conn.send(content: Data(hdr.utf8), completion: .contentProcessed { _ in })
        let v = Viewer(conn)
        viewers[ObjectIdentifier(conn)] = v
        viewerCount = viewers.count
        onViewersChanged?(viewers.count)
        if let last = lastChunk { v.pending = last; pump(v) }
        drain(conn)   // detect the browser closing the tab
    }

    /// Keep reading (and discarding) so a peer close surfaces as isComplete and
    /// the viewer is torn down promptly.
    private func drain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { conn.cancel(); return }
            self.drain(conn)
        }
    }

    private func removeViewer(_ conn: NWConnection) {
        guard viewers.removeValue(forKey: ObjectIdentifier(conn)) != nil else { return }
        viewerCount = viewers.count
        onViewersChanged?(viewers.count)
    }
}
