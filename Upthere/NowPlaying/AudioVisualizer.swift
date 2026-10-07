import Accelerate
import AudioToolbox
import CoreAudio
import QuartzCore
import os

private nonisolated let visualizerLog = Logger(subsystem: "dev.upthere.app", category: "visualizer")

/// Latest band levels (0…1), written by the audio queue, read by the
/// bars' display link. A lock-guarded SIMD4: no allocation on either side.
nonisolated final class LevelStore: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var levels = SIMD4<Float>(repeating: 0)
    private var stamp: CFTimeInterval = 0

    func write(_ value: SIMD4<Float>) {
        os_unfair_lock_lock(&lock)
        levels = value
        stamp = CACurrentMediaTime()
        os_unfair_lock_unlock(&lock)
    }

    /// Levels and how old they are, in seconds.
    func read() -> (levels: SIMD4<Float>, age: CFTimeInterval) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (levels, CACurrentMediaTime() - stamp)
    }
}

/// Taps the playing app's audio with a Core Audio process tap (macOS 14.2+)
/// and turns it into four band levels for the sound bars.
///
/// Costs nothing until started; runs only while music plays with the live
/// visualizer on. macOS asks once for permission to capture app audio.
final class AudioVisualizer {
    static let shared = AudioVisualizer()

    let store = LevelStore()
    private(set) var runningBundleID: String?
    /// Set when the tap couldn't be created (e.g. permission denied); not
    /// retried until the setting or the player changes.
    private var failedBundleID: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.upthere.visualizer", qos: .userInteractive)

    func run(for bundleID: String?) {
        guard bundleID != runningBundleID else { return }
        stop()
        guard let bundleID, bundleID != failedBundleID else { return }
        do {
            try start(bundleID: bundleID)
            runningBundleID = bundleID
            failedBundleID = nil
        } catch {
            visualizerLog.error("audio tap failed: \(error.localizedDescription, privacy: .public)")
            failedBundleID = bundleID
            stop()
        }
    }

    func resetFailures() { failedBundleID = nil }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        runningBundleID = nil
        store.write(.zero)
    }

    private func start(bundleID: String) throws {
        let processes = Self.audioProcesses(matching: bundleID)
        let description =
            processes.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Upthere visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")
        guard let outputUID = Self.defaultOutputUID() else { throw VisualizerError.noOutput }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Upthere Visualizer",
            kAudioAggregateDeviceUIDKey: "dev.upthere.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create device")

        let sampleRate = Self.sampleRate(of: aggregateID) ?? 48_000
        let analyzer = SpectrumAnalyzer(sampleRate: Float(sampleRate), store: store)
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, Self.ioBlock(analyzer)), "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
        visualizerLog.info("tapping \(processes.count) process(es) of \(bundleID, privacy: .public)")
    }

    /// Built outside the main actor: Core Audio calls it on the audio queue.
    nonisolated private static func ioBlock(_ analyzer: SpectrumAnalyzer) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in analyzer.process(input) }
    }

    enum VisualizerError: Error { case status(String, OSStatus), noOutput }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw VisualizerError.status(step, status) }
    }

    // MARK: Core Audio queries

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Audio process objects belonging to an app, including its helpers
    /// (e.g. `com.spotify.client.helper`).
    static func audioProcesses(matching bundleID: String) -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter { id in
            guard let bundle = stringProperty(id, kAudioProcessPropertyBundleID) else { return false }
            return bundle == bundleID || bundle.hasPrefix(bundleID + ".")
        }
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func sampleRate(of device: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }
}

/// Mono-mixes incoming buffers, runs a 1024-point FFT every 512 samples and
/// reduces it to four bands with per-band automatic gain. Runs on the audio
/// queue only; buffers are preallocated.
nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
    private static let size = 1024
    private static let hop = 512
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var ring = [Float](repeating: 0, count: size)
    private var filled = 0
    private var real = [Float](repeating: 0, count: size / 2)
    private var imag = [Float](repeating: 0, count: size / 2)
    private var windowed = [Float](repeating: 0, count: size)
    private var power = [Float](repeating: 0, count: size / 2)
    private let bands: [Range<Int>]
    private var peaks = SIMD4<Float>(repeating: 1e-6)
    private let store: LevelStore

    init(sampleRate: Float, store: LevelStore) {
        self.store = store
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Float(Self.size))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        let binHz = sampleRate / Float(Self.size)
        func bin(_ hz: Float) -> Int { min(Self.size / 2, max(1, Int(hz / binHz))) }
        bands = [bin(40)..<bin(220), bin(220)..<bin(900), bin(900)..<bin(3500), bin(3500)..<bin(12_000)]
    }

    func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        let scale = 1 / Float(channels)
        // Non-interleaved stereo arrives as two buffers; use the first only.
        var frame = 0
        while frame < frames {
            var sum: Float = 0
            var channel = 0
            while channel < channels {
                sum += samples[frame * channels + channel]
                channel += 1
            }
            frame += 1
            ring[filled] = sum * scale
            filled += 1
            if filled == Self.size {
                analyze()
                // Keep the second half for 50% overlap.
                for i in 0..<Self.hop { ring[i] = ring[i + Self.hop] }
                filled = Self.hop
            }
        }
    }

    private func analyze() {
        vDSP.multiply(ring, window, result: &windowed)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        var levels = SIMD4<Float>(repeating: 0)
        for index in 0..<4 {
            let range = bands[index]
            guard !range.isEmpty else { continue }
            var sum: Float = 0
            power.withUnsafeBufferPointer {
                vDSP_sve($0.baseAddress! + range.lowerBound, 1, &sum, vDSP_Length(range.count))
            }
            let energy = sum / Float(range.count)
            // Automatic gain: decaying per-band peak, so quiet and loud
            // tracks both use the full height.
            peaks[index] = max(energy, peaks[index] * 0.995)
            let ratio = energy / max(peaks[index], 1e-9)
            levels[index] = min(1, max(0, (10 * log10(max(ratio, 1e-6)) + 30) / 30))
        }
        store.write(levels)
    }
}
