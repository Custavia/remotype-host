import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware H.264 encoder for the Cast DIRECT path (CASTING.md §6.5 Tier 1).
/// Takes the full-display CVImageBuffers from CaptureController's raw sink and
/// emits Annex-B access units the Pion sidecar packetizes to RTP. Pinned to
/// Constrained-Baseline-compatible settings (no B-frames, CAVLC, frequent IDR)
/// so the frozen-firmware legacy Chromecast can decode it (§6.5).
///
/// THREADING: `encode` is called from CaptureController's serial capture queue;
/// VideoToolbox invokes the per-frame output handler on its own thread. The
/// `onAccessUnit` closure may therefore fire on a VT thread — the sidecar bridge
/// it feeds writes to a socket on its own queue, so that's fine.
final class CastEncoder {
    /// Emitted per coded frame: Annex-B bytes (SPS/PPS prepended on keyframes) and
    /// the presentation timestamp in microseconds (mach clock, for §6.3 lip-sync).
    var onAccessUnit: ((Data, UInt64) -> Void)?

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let legacy: Bool
    private var bitrate: Int
    private let fps: Int32
    private var forceKeyframeNext = false
    private var firstPTS: CMTime?   // normalizes the mach-clock PTS to start at ~0

    // Steady-framerate keepalive: ScreenCaptureKit is change-driven, so a static
    // screen delivers no frames and the stream stalls (black). A timer re-encodes
    // the last frame at fps when SCK is idle, keeping HLS segments flowing.
    private let encQueue = DispatchQueue(label: "remotype.cast.enc")
    private let hostClock = CMClockGetHostTimeClock()
    private var lastImageBuffer: CVImageBuffer?
    private var lastRawPTS: CMTime = .invalid
    private var lastEmittedNorm: CMTime?
    private var keepalive: DispatchSourceTimer?

    /// - legacy: pins the conservative §6.5 profile (IDR every 1 s vs 2 s).
    init(width: Int, height: Int, fps: Int, bitrate: Int, legacy: Bool) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = Int32(fps)
        self.bitrate = bitrate
        self.legacy = legacy
    }

    func start() -> Bool {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,           // nil → encode with a per-frame output handler
            refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            HostLog.write("cast encoder create failed \(status)")
            return false
        }
        self.session = session
        configure(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
        startKeepalive()
        return true
    }

    /// Re-encode the last frame ONLY when SCK has been idle a while, so a static
    /// screen keeps producing a steady stream without ever interfering with live
    /// frames (a fast keepalive collides with real-frame timestamps and the
    /// monotonic guard then drops them, starving the stream). While the screen is
    /// active (frames < idleGap apart), the keepalive never fires.
    private static let idleGap = 0.4   // seconds with no real frame before we repeat one
    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: encQueue)
        t.schedule(deadline: .now() + Self.idleGap, repeating: Self.idleGap)
        t.setEventHandler { [weak self] in
            guard let self, let last = self.lastImageBuffer, self.lastRawPTS.isValid else { return }
            let now = CMClockGetTime(self.hostClock)
            if CMTimeGetSeconds(CMTimeSubtract(now, self.lastRawPTS)) < Self.idleGap { return } // frames flowing → skip
            self.doEncode(last, raw: now)
        }
        t.resume()
        keepalive = t
    }

    private func configure(_ session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames (low latency + legacy)
        // Baseline (CAVLC, no FMO/ASO) only for the frozen-firmware legacy path.
        // Our WebRTC receivers decode HIGH fine, and High's CABAC + 8x8 transform
        // is materially sharper on screen content at the same bitrate — which is
        // exactly what small text needs.
        set(kVTCompressionPropertyKey_ProfileLevel,
            legacy ? kVTProfileLevel_H264_Baseline_AutoLevel
                   : kVTProfileLevel_H264_High_AutoLevel)
        if #available(macOS 11.0, *) {
            // Cap how far the rate controller may degrade quality. 50 let text
            // smear into mush on a busy frame; screen content stays legible only
            // if the encoder is made to spend bits instead of raising QP.
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, (legacy ? 50 : 38) as CFNumber)
            // Never let a static desktop drop below a quality floor either.
            if #available(macOS 13.0, *) {
                set(kVTCompressionPropertyKey_MinAllowedFrameQP, 15 as CFNumber)
            }
        }
        // Legacy receivers recover slowly from a lost P-frame — keyframe every 1 s;
        // DIRECT (capable sinks) every 2 s to save bitrate.
        let gop = legacy ? fps : fps * 2
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, gop as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (legacy ? 1.0 : 2.0) as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        applyBitrate(session, bitrate)
    }

    private func applyBitrate(_ session: VTCompressionSession, _ bps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // A 1 s data-rate ceiling at ~1.4× average tames bursts for the sink's jitter buffer.
        let bytesPerSec = Double(bps) / 8.0 * 1.4
        let limits = [bytesPerSec as CFNumber, 1.0 as CFNumber] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// Live bitrate change from the §6.4 BWE ladder (sidecar TWCC → rung → here).
    func setBitrate(_ bps: Int) {
        bitrate = bps
        guard let session else { return }
        applyBitrate(session, bps)
    }

    /// Force an IDR on the next frame (display switch / resume, §6.4).
    func requestKeyframe() { forceKeyframeNext = true }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.imageBuffer != nil else { return }
        let imageBuffer = sampleBuffer.imageBuffer!
        let raw = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encQueue.async { [weak self] in self?.doEncode(imageBuffer, raw: raw) }
    }

    /// The single encode path (real frames + keepalive), serialized on encQueue.
    private func doEncode(_ imageBuffer: CVImageBuffer, raw: CMTime) {
        guard let session else { return }
        // Normalize PTS to start near 0: SCK hands us the absolute mach clock
        // (hundreds of thousands of seconds), which overflows the MPEG-TS 33-bit
        // timestamp (§6.5 HLS) and breaks VideoToolbox's keyframe-interval timing.
        if firstPTS == nil { firstPTS = raw }
        let pts = CMTimeSubtract(raw, firstPTS ?? raw)
        // Monotonic guard: VideoToolbox requires strictly increasing PTS.
        if let last = lastEmittedNorm, CMTimeCompare(pts, last) <= 0 { return }
        lastEmittedNorm = pts
        lastImageBuffer = imageBuffer   // held for the keepalive
        lastRawPTS = raw
        var props: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: imageBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard status == noErr, let buffer, let self else { return }
            self.emit(buffer, pts: pts)
        }
    }

    // MARK: AVCC → Annex-B

    private func emit(_ sample: CMSampleBuffer, pts: CMTime) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        let keyframe = isKeyframe(sample)

        var out = Data()
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sample) {
            // Prepend SPS/PPS on every IDR so a receiver that joined late can decode.
            for idx in 0..<parameterSetCount(fmt) {
                if let ps = parameterSet(fmt, idx) {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(ps)
                }
            }
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let base = dataPointer else { return }

        // AVCC: [4-byte big-endian length][NAL] … → replace each length with 00 00 00 01.
        var offset = 0
        while offset + 4 <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, base + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            let start = offset + 4
            let end = start + Int(nalLength)
            guard end <= totalLength else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            base.withMemoryRebound(to: UInt8.self, capacity: totalLength) { p in
                out.append(UnsafeBufferPointer(start: p + start, count: Int(nalLength)))
            }
            offset = end
        }

        let ptsUS = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        onAccessUnit?(out, ptsUS)
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(arr) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
        // NotSync absent or false ⇒ this IS a sync sample (IDR).
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        var notSync: UnsafeRawPointer?
        if CFDictionaryGetValueIfPresent(dict, key, &notSync), let notSync {
            return !CFBooleanGetValue(unsafeBitCast(notSync, to: CFBoolean.self))
        }
        return true
    }

    private func parameterSetCount(_ fmt: CMFormatDescription) -> Int {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return count
    }

    private func parameterSet(_ fmt: CMFormatDescription, _ idx: Int) -> Data? {
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: idx,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let ptr else { return nil }
        return Data(bytes: ptr, count: size)
    }

    func stop() {
        keepalive?.cancel()
        keepalive = nil
        lastImageBuffer = nil
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}
