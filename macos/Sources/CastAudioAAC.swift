import Foundation
import AVFoundation

/// Encodes the Mac's system audio (48 kHz stereo Int16 PCM, from `AudioCapture`)
/// to **AAC-LC ADTS** frames for the Tier-3 HLS mux (CASTING.md §6.5). Each frame
/// is one 1024-sample AAC packet with a 7-byte ADTS header prepended, matching the
/// muxer's audio-slot cadence (`hls.go`), which fills each slot with a real frame
/// when one is available and silence otherwise.
///
/// THREADING: one serial queue owns the converter + input queue; `feed` and the
/// emit callback are serialized on it. The AVAudioConverter is stateful — every
/// PCM buffer is handed to it exactly once (via the pull block) and never re-fed.
final class CastAudioAAC {
    private let queue = DispatchQueue(label: "remotype.cast.aac")
    private let inFormat: AVAudioFormat   // 48 kHz stereo Int16 interleaved (AudioCapture stereo)
    private let aacFormat: AVAudioFormat  // AAC-LC 48 kHz stereo, 1024 frames/packet
    private var converter: AVAudioConverter?
    private var inputQueue: [AVAudioPCMBuffer] = []
    private var onFrame: ((Data) -> Void)?

    init() {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
                                 channels: 2, interleaved: true)!
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        aacFormat = AVAudioFormat(streamDescription: &asbd)!
    }

    func start(onFrame: @escaping (Data) -> Void) {
        queue.async {
            self.onFrame = onFrame
            self.inputQueue.removeAll()
            let conv = AVAudioConverter(from: self.inFormat, to: self.aacFormat)
            conv?.bitRate = 128_000
            self.converter = conv
        }
    }

    func stop() {
        queue.async {
            self.onFrame = nil
            self.converter = nil
            self.inputQueue.removeAll()
        }
    }

    /// Feed one PCM chunk (48 kHz stereo Int16 interleaved) from AudioCapture.
    func feed(_ pcm: Data) {
        queue.async {
            guard self.converter != nil, self.onFrame != nil, pcm.count >= 4 else { return }
            let frames = AVAudioFrameCount(pcm.count / 4)   // 2 ch × 2 bytes
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: self.inFormat, frameCapacity: frames),
                  let dst = buf.int16ChannelData?[0] else { return }
            buf.frameLength = frames
            pcm.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(dst, src, pcm.count) }
            }
            self.inputQueue.append(buf)
            self.drainLocked()
        }
    }

    /// Pull every complete AAC packet the converter can produce from the queued
    /// PCM, emit each as an ADTS frame. On [queue].
    private func drainLocked() {
        guard let conv = converter else { return }
        while true {
            let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8,
                                              maximumPacketSize: conv.maximumOutputPacketSize)
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, outStatus in
                if self.inputQueue.isEmpty { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                return self.inputQueue.removeFirst()
            }
            if status == .error { return }
            emitPackets(out)
            // No more output this round (encoder primed / ran out of input).
            if out.packetCount == 0 || status == .inputRanDry || status == .endOfStream { return }
        }
    }

    private func emitPackets(_ buf: AVAudioCompressedBuffer) {
        guard buf.packetCount > 0, let onFrame, let descs = buf.packetDescriptions else { return }
        let base = buf.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(buf.packetCount) {
            let size = Int(descs[i].mDataByteSize)
            let start = Int(descs[i].mStartOffset)
            guard size > 0 else { continue }
            var frame = Data(capacity: 7 + size)
            frame.append(contentsOf: Self.adtsHeader(payloadLen: size))
            frame.append(base + start, count: size)
            onFrame(frame)
        }
    }

    /// 7-byte ADTS header for AAC-LC / 48 kHz (freq-index 3) / 2 channels, no CRC.
    /// Only the 13-bit frame length (total = 7 + payload) varies per frame.
    private static func adtsHeader(payloadLen: Int) -> [UInt8] {
        let len = 7 + payloadLen
        return [
            0xFF,                                   // syncword high
            0xF1,                                   // syncword low, MPEG-4, layer 0, no CRC
            0x4C,                                   // profile=AAC-LC, freq-idx=3, chan_hi=0
            UInt8(0x80 | ((len >> 11) & 0x03)),     // chan_lo=2, framelen[12:11]
            UInt8((len >> 3) & 0xFF),               // framelen[10:3]
            UInt8(((len & 0x07) << 5) | 0x1F),      // framelen[2:0], buffer-fullness[10:6]
            0xFC,                                   // buffer-fullness[5:0], frames-1=0
        ]
    }
}
