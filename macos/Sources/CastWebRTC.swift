import Foundation

/// Cast receiver configuration.
enum CastConfig {
    /// The Cast receiver App ID the host LAUNCHes over CASTv2. Our custom receiver
    /// (`custavia.com/remotype/cast-receiver/`) registered in the Google Cast console
    /// as `93EC8A58` — this runs our WebRTC receiver over the custom namespace, so the
    /// host takes the low-latency WebRTC branch (Server.startDirectCast: `useHLS` is
    /// `appID == "CC1AD845"`, now false → WebRTC). `CC1AD845` (Google's Default Media
    /// Receiver, HLS-only) remains the automatic fallback when WebRTC can't connect.
    static let appID = "93EC8A58"
}

/// Supervises the bundled Go/Pion sidecar (`remotype-cast-helper`) that owns the
/// WebRTC PeerConnection for Cast DIRECT (CASTING.md §6.5 Tier 1). The Swift host
/// captures + H.264-encodes; this bridge streams the encoded media to the sidecar
/// over a unix socket and relays SDP/ICE as JSON lines on the sidecar's stdio,
/// which Server.swift forwards over `cast.sig`.
///
/// Control (stdio): we send {"t":"start"|"answer"|"ice"|"stop"}; the sidecar
/// sends {"t":"offer"|"ice"|"state"|"bwe"|"ready"|"error"}. Media (unix socket):
/// length-prefixed frames — H.264 access units + stereo PCM (§7.4 framing).
final class CastWebRTC {
    /// A local SDP/ICE message to relay to the receiver via cast.sig: (kind, data).
    var onSignal: ((String, [String: Any]) -> Void)?
    /// Sidecar's TWCC/GCC bandwidth estimate (bps) → the encoder's §6.4 ladder.
    var onBitrate: ((Int) -> Void)?
    /// ICE connected — the Server starts capture + encoder + audio now.
    var onConnected: (() -> Void)?
    /// The sidecar exited / the peer failed — the Server tears the session down.
    var onFailed: (() -> Void)?
    /// The host can't reach the sink from where it is (remote PC / different LAN) —
    /// the pivot to phone-driven fallback (Tier 2/3, CASTING.md §6.5 cascade).
    var onReachFail: ((String) -> Void)?   // reason: "connect" | "launch"

    private let ioQueue = DispatchQueue(label: "remotype.cast.webrtc")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuf = Data()
    private var socketPath = ""
    private var mediaFD: Int32 = -1
    private var connectedFired = false
    private var stopped = false

    // Bounded outbound media buffer: drop video under backpressure so a slow
    // sidecar can never backlog the capture queue (memory: realtime send must
    // gate/coalesce, never fire-and-forget). Audio is tiny — never dropped.
    private var inflightBytes = 0
    private let inflightLock = NSLock()
    private static let inflightCap = 3 << 20   // 3 MiB

    /// Launch the sidecar and open the session. Returns false if the helper binary
    /// is missing (the Server answers cast.err → "couldn't start", best-effort).
    /// castHost/castPort drive the host-driven CASTv2 path (§6.6): the sidecar
    /// LAUNCHes appID on the sink itself and relays SDP/ICE over the Cast namespace
    /// — no phone Cast SDK. Omit castHost for the phone-driven cast.sig relay.
    func start(token: String, computer: String, audio: Bool, legacy: Bool, fps: Int,
               castHost: String? = nil, castPort: Int? = nil, appID: String = CastConfig.appID,
               hls: Bool = false) -> Bool {
        guard let helper = Self.helperURL() else {
            HostLog.write("cast helper binary not found")
            return false
        }
        socketPath = "/tmp/remotype-cast-\(getpid())-\(UInt32.random(in: .min ... .max)).sock"

        let p = Process()
        p.executableURL = helper
        p.arguments = ["--media-socket", socketPath]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // DEBUG: sidecar stderr → a log file so we can diagnose the cast on-device.
        // APPEND, never truncate: a WebRTC attempt that falls back to HLS spawns a
        // SECOND sidecar, and re-opening at offset 0 had the fallback overwrite the
        // very trace (offer SDP, receiver errors) that explains why the first
        // attempt failed. Each session announces itself so runs stay separable.
        let logPath = "/tmp/remotype-cast.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let logHandle = FileHandle(forWritingAtPath: logPath)
        logHandle?.seekToEndOfFile()
        if let logHandle {
            let banner = "\n===== cast session \(hls ? "HLS" : "WebRTC") @ \(Date()) =====\n"
            logHandle.write(Data(banner.utf8))
        }
        p.standardError = logHandle ?? FileHandle.nullDevice
        stdinHandle = inPipe.fileHandleForWriting
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            self?.ioQueue.async { self?.onStdout(d) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.ioQueue.async { self?.handleExit() }
        }
        do {
            try p.run()
        } catch {
            HostLog.write("cast helper launch failed")
            return false
        }
        process = p
        var msg: [String: Any] = ["t": "start", "token": token, "fps": fps,
                                  "legacy": legacy, "audio": audio, "computer": computer]
        if let castHost {
            msg["castHost"] = castHost
            msg["castPort"] = castPort ?? 8009
            msg["appID"] = appID
        }
        if hls { msg["hls"] = true }
        sendControl(msg)
        return true
    }

    /// A receiver→host signaling message arrived over cast.sig (answer | ice).
    func applyRemote(kind: String, data: [String: Any]) {
        sendControl(["t": kind, "data": data])
    }

    func writeVideo(_ annexB: Data, ptsUS: UInt64) { writeFrame(kind: 1, ptsUS: ptsUS, payload: annexB, isVideo: true) }
    func writeAudio(_ pcm: Data, ptsUS: UInt64)    { writeFrame(kind: 2, ptsUS: ptsUS, payload: pcm, isVideo: false) }

    /// Drive the SINK's own output level (CASTv2 SET_VOLUME) — the phone's TV
    /// volume buttons. Previously an accepted no-op on this path.
    func setVolume(_ level: Double) { sendControl(["t": "volume", "level": min(max(level, 0), 1)]) }
    /// One AAC-LC ADTS frame for the HLS mux (kind 3). PTS is slot-assigned by the
    /// muxer, so it's ignored here (0). Audio is small — never dropped.
    func writeAudioAAC(_ adts: Data)               { writeFrame(kind: 3, ptsUS: 0, payload: adts, isVideo: false) }

    func stop() {
        // STRONG self on purpose: the Server drops its reference immediately after
        // calling stop() (castWebRTC = nil), so a [weak self] capture would be nil
        // by the time this runs and the "stop" would never reach the sidecar —
        // leaving the sink stuck casting. The strong capture releases when the
        // block (and its delayed child) finish.
        ioQueue.async {
            if self.stopped { return }
            self.stopped = true
            // Graceful: the sidecar processes "stop" → sends the receiver a CASTv2
            // STOP so the sink CLEARS (doesn't sit stuck on the last frame). Give it
            // a moment before force-terminating.
            self.sendControlLocked(["t": "stop"])
            if self.mediaFD >= 0 { close(self.mediaFD); self.mediaFD = -1 }
            let proc = self.process
            proc?.terminationHandler = nil
            self.process = nil
            let path = self.socketPath
            self.ioQueue.asyncAfter(deadline: .now() + 0.6) {
                proc?.terminate()
                self.stdinHandle = nil
                if !path.isEmpty { unlink(path) }
            }
        }
    }

    // MARK: stdio control

    private func sendControl(_ obj: [String: Any]) {
        ioQueue.async { [weak self] in self?.sendControlLocked(obj) }
    }

    private func sendControlLocked(_ obj: [String: Any]) {
        guard let stdin = stdinHandle,
              var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        line.append(0x0A)
        do { try stdin.write(contentsOf: line) } catch { /* sidecar gone */ }
    }

    /// Accumulate stdout and dispatch each complete JSON line. On [ioQueue].
    private func onStdout(_ data: Data) {
        stdoutBuf.append(data)
        while let nl = stdoutBuf.firstIndex(of: 0x0A) {
            let line = stdoutBuf.subdata(in: stdoutBuf.startIndex..<nl)
            stdoutBuf.removeSubrange(stdoutBuf.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let t = obj["t"] as? String else { continue }
            switch t {
            case "offer", "ice":
                if let d = obj["data"] as? [String: Any] { onSignal?(t, d) }
            case "state":
                if (obj["ice"] as? String) == "connected", !connectedFired {
                    connectedFired = true
                    connectMediaLocked()
                    onConnected?()
                }
            case "bwe":
                if let bps = obj["bps"] as? Int { onBitrate?(bps) }
            case "ready":
                break   // sidecar accepted the media socket
            case "reachfail":
                // "connect" = couldn't even reach the sink (true unreachable).
                // "launch" = reached it but the receiver app wouldn't launch (an
                // unpublished/not-yet-propagated custom receiver) → the host retries
                // this same sink on the HLS path automatically.
                let reason = obj["msg"] as? String ?? ""
                HostLog.write("cast reachfail (\(reason))")
                onReachFail?(reason)
            case "error":
                HostLog.write("cast sidecar error")
            default:
                break
            }
        }
    }

    private func handleExit() {
        guard !stopped else { return }
        stopped = true
        if mediaFD >= 0 { close(mediaFD); mediaFD = -1 }
        HostLog.write("cast sidecar exited")
        onFailed?()
    }

    // MARK: media socket (Swift connects to the sidecar's unix listener)

    private func connectMediaLocked() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathC = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathC.count) { dst in
                pathC.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: min(src.count, 104))
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if r == 0 {
            mediaFD = fd
        } else {
            close(fd)
            HostLog.write("cast media socket connect failed")
        }
    }

    private func writeFrame(kind: UInt8, ptsUS: UInt64, payload: Data, isVideo: Bool) {
        // Backpressure guard BEFORE dispatch, so a backlog can't grow unbounded.
        inflightLock.lock()
        if isVideo && inflightBytes > Self.inflightCap {
            inflightLock.unlock()
            return   // drop this frame; the encoder's next IDR resyncs the receiver
        }
        inflightBytes += payload.count
        inflightLock.unlock()

        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.inflightLock.lock(); self.inflightBytes -= payload.count; self.inflightLock.unlock()
            }
            guard self.mediaFD >= 0 else { return }
            let n = UInt32(1 + 8 + payload.count)
            var hdr = [UInt8]()
            hdr.reserveCapacity(13)
            hdr.append(UInt8((n >> 24) & 0xff)); hdr.append(UInt8((n >> 16) & 0xff))
            hdr.append(UInt8((n >> 8) & 0xff));  hdr.append(UInt8(n & 0xff))
            hdr.append(kind)
            for i in 0..<8 { hdr.append(UInt8((ptsUS >> (56 - 8 * i)) & 0xff)) }
            if !self.writeAll(hdr) { self.mediaFailLocked(); return }
            let ok = payload.withUnsafeBytes { buf -> Bool in
                self.writeAll(buf.bindMemory(to: UInt8.self))
            }
            if !ok { self.mediaFailLocked() }
        }
    }

    private func writeAll<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        let arr = Array(bytes)
        return arr.withUnsafeBytes { raw -> Bool in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < raw.count {
                let w = write(mediaFD, base + off, raw.count - off)
                if w > 0 { off += w }
                else if w < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }

    private func mediaFailLocked() {
        guard mediaFD >= 0 else { return }
        close(mediaFD); mediaFD = -1
        HostLog.write("cast media socket write failed")
    }

    // MARK: helper location

    /// True when the WebRTC sidecar is bundled — gates the host's `direct` hi flag.
    static var isAvailable: Bool { helperURL() != nil }

    private static func helperURL() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["REMOTYPE_CAST_HELPER"],
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/remotype-cast-helper")
        return fm.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }
}
