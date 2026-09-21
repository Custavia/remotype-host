import Foundation
import CoreAudio
import AudioToolbox

/// One frame of the vitals stream: percentages 0–100.
/// `vol` is -1 when there is no readable default output device; `np` is nil
/// when nothing is playing or MediaRemote is unavailable (see PROTOCOL.md).
struct VitalsSnapshot {
    let cpu: Int
    let ram: Int
    let vol: Int
    let np: String?
}

/// Samples host vitals for the `{"t":"vitals"}` stream. Everything here is
/// non-blocking: CPU/RAM/volume are cheap synchronous reads; now-playing is
/// an async MediaRemote callback whose latest delivery is cached — `sample()`
/// returns the cache and kicks off a refresh for the next tick.
///
/// Queue confinement: all state is touched on .main only — `sample()` is
/// called from the Server's main-queue timer and the MediaRemote callback is
/// delivered on .main (we pass that queue in).
final class VitalsSampler {

    func sample() -> VitalsSnapshot {
        requestNowPlaying()
        return VitalsSnapshot(cpu: cpuPercent(),
                              ram: ramPercent(),
                              vol: volumePercent(),
                              np: cachedNowPlaying)
    }

    // MARK: CPU — host_processor_info tick deltas

    /// Cumulative (used, total) scheduler ticks summed over all cores from the
    /// previous sample. The first call has no baseline: it seeds and returns 0.
    private var prevCPUTicks: (used: UInt64, total: UInt64)?
    private var lastCPU = 0

    private func cpuPercent() -> Int {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return lastCPU }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var used: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            // Ticks are 32-bit counters on the wire; widen before summing.
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys  = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            used += user + sys + nice
            total += user + sys + nice + idle
        }
        guard let prev = prevCPUTicks else {
            prevCPUTicks = (used, total)   // first call: seed, report 0
            return 0
        }
        // A per-core 32-bit counter wrapping makes the sums go backwards;
        // reseed instead of reporting a garbage delta.
        guard used >= prev.used, total > prev.total else {
            prevCPUTicks = (used, total)
            return lastCPU
        }
        let pct = Int(((used - prev.used) * 100) / (total - prev.total))
        prevCPUTicks = (used, total)
        lastCPU = min(100, max(0, pct))
        return lastCPU
    }

    // MARK: RAM — host_statistics64

    private func ramPercent() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        // "Used" = active + wired + compressed — what Activity Monitor's
        // memory-pressure story counts as spoken-for.
        let used = (UInt64(stats.active_count)
                    + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return 0 }
        return min(100, max(0, Int((used * 100) / total)))
    }

    // MARK: Volume — CoreAudio default output device

    private func volumePercent() -> Int {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return -1 }

        var volume = Float32(0)
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &volume) == noErr
        else { return -1 }
        return min(100, max(0, Int((volume * 100).rounded())))
    }

    // MARK: Now playing — MediaRemote private framework

    /// `np` strings are capped at this many characters before hitting the wire.
    private static let nowPlayingCharCap = 120

    private typealias MRNowPlayingInfoFn =
        @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void

    /// Resolved exactly once, lazily, on first use. If the framework or symbol
    /// is missing (or Apple locks it down further) this stays nil and `np` is
    /// simply absent — never an error the phone has to handle.
    private lazy var mrGetNowPlayingInfo: MRNowPlayingInfoFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
            let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
        else { return nil }
        return unsafeBitCast(sym, to: MRNowPlayingInfoFn.self)
    }()

    /// Last value the async MediaRemote callback delivered. The callback may
    /// never fire (macOS 15.4+ withholds now-playing data from unentitled
    /// processes — see PROTOCOL.md) — then this stays nil forever, by design.
    private var cachedNowPlaying: String?

    private func requestNowPlaying() {
        guard let fn = mrGetNowPlayingInfo else { return }
        fn(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            guard let dict = info as? [String: Any] else {
                self.cachedNowPlaying = nil
                return
            }
            let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
            let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
            let joined: String
            switch (artist.isEmpty, title.isEmpty) {
            case (false, false): joined = "\(artist) — \(title)"
            case (true, false):  joined = title
            case (false, true):  joined = artist
            case (true, true):   self.cachedNowPlaying = nil; return
            }
            self.cachedNowPlaying = String(joined.prefix(Self.nowPlayingCharCap))
        }
    }
}
