import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Computer-audio streaming: a ScreenCaptureKit stream with
/// `capturesAudio` on, tapping the Mac's system audio. Each delivered PCM buffer
/// is downmixed to MONO and converted to 48 kHz Int16, then handed to `onChunk`
/// as raw little-endian bytes. The Server base64s it and ships it on the socket
/// pinned to the subscriber — exactly the TV-frame path, opposite direction.
///
/// Lifecycle mirrors CaptureController: started on `aud.sub`, stopped on
/// `aud.unsub` and EVERY connection teardown path. THREADING: one serial queue
/// owns all state + the SCK sample callback; an `epoch` drops an async start
/// whose subscriber went away. Permission: the same Screen Recording grant TV
/// needs (the Server preflights it before starting this).
@available(macOS 13.0, *)
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Wire sample rate — also what the phone plays back. Matches SCStream's
    /// native 48 kHz so the only conversion is stereo→mono + Float32→Int16.
    static let sampleRate: Double = 48000

    private let queue = DispatchQueue(label: "remotype.audio")
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var chunkHandler: ((Data) -> Void)?
    private var epoch = 0

    /// What we ship: 48 kHz Int16 interleaved. Mono for the phone monitor / browser
    /// cast; STEREO for Cast DIRECT (§6.2 taps before the mono downmix).
    private let outFormat: AVAudioFormat

    /// - stereo: true for the Cast DIRECT Opus path (2 ch); false (default) for the
    ///   phone monitor + browser cast (1 ch), unchanged.
    init(stereo: Bool = false) {
        outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: AudioCapture.sampleRate,
                                  channels: stereo ? 2 : 1, interleaved: true)!
        super.init()
    }

    func start(onChunk: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.epoch += 1
            let myEpoch = self.epoch
            self.chunkHandler = onChunk
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
                [weak self] content, error in
                self?.queue.async {
                    guard let self, myEpoch == self.epoch else { return }
                    guard let display = content?.displays.first else {
                        NSLog("RemotypeHost: audio shareable content failed: \(String(describing: error))")
                        return
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.capturesAudio = true
                    config.sampleRate = Int(AudioCapture.sampleRate)
                    config.channelCount = 2
                    config.excludesCurrentProcessAudio = true   // never echo our own (silent) output
                    // We only add a .audio output, never .screen, so no frames are
                    // delivered — keep the mandatory video path tiny + slow.
                    config.width = 2
                    config.height = 2
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    do {
                        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                        stream.startCapture { err in
                            if let err { NSLog("RemotypeHost: audio startCapture failed: \(err)") }
                        }
                        self.stream = stream
                    } catch {
                        NSLog("RemotypeHost: audio addStreamOutput failed: \(error)")
                    }
                }
            }
        }
    }

    func stop() { queue.async { [weak self] in self?.stopLocked() } }

    /// MUST run on [queue]. Bumps epoch so an in-flight start's completion drops,
    /// then tears the stream + handler down.
    private func stopLocked() {
        epoch += 1
        if let stream { try? stream.removeStreamOutput(self, type: .audio) }
        stream?.stopCapture { _ in }
        stream = nil
        converter = nil
        chunkHandler = nil
    }

    // SCStreamOutput — on [queue].
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let handler = chunkHandler,
              let pcm = sampleBuffer.toPCMBuffer() else { return }
        // Build the converter lazily once the input format is known (and rebuild
        // if SCK ever hands us a different one).
        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: outFormat)
        }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: AVAudioFrameCount(pcm.frameLength)),
              pcm.frameLength > 0 else { return }
        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return pcm
        }
        guard convErr == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        // Interleaved: ch[0] holds all channels; account for channelCount (1 or 2).
        let byteCount = Int(out.frameLength) * Int(outFormat.channelCount) * MemoryLayout<Int16>.size
        handler(Data(bytes: ch[0], count: byteCount))
    }
}

extension CMSampleBuffer {
    /// Wrap an SCStream audio sample buffer as an AVAudioPCMBuffer by copying the
    /// PCM out via its format description's ASBD (48 kHz Float32 deinterleaved).
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
