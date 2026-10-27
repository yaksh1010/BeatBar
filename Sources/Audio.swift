import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BeatBar.log")

    static func write(_ message: String) {
        NSLog("%@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Capturing what the Mac is playing

/// Mono samples written by the audio thread and read by the UI thread.
final class SampleRingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private let lock = NSLock()

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: capacity)
    }

    func append(_ data: UnsafePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        defer { lock.unlock() }
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += data[frame * channels + channel] }
            storage[writeIndex] = sum / Float(channels)
            writeIndex = (writeIndex + 1) % storage.count
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for i in storage.indices { storage[i] = 0 }
    }

    func latest(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var result = [Float](repeating: 0, count: count)
        var index = (writeIndex - count + storage.count) % storage.count
        for i in 0..<count {
            result[i] = storage[index]
            index = (index + 1) % storage.count
        }
        return result
    }
}

struct AudioError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

/// Listens to all system audio through a Core Audio process tap (macOS 14.2+).
/// Needs the "System Audio Recording" permission; macOS asks the first time.
final class SystemAudioTap {
    let buffer = SampleRingBuffer(capacity: 8192)
    private(set) var sampleRate: Double = 48_000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.beatbar.audio", qos: .userInteractive)

    /// Set on the main thread as soon as a start is requested, so it is never started twice.
    private(set) var isActive = false
    /// Creating the tap blocks while macOS shows its permission prompt, so it runs here, off the main thread.
    private let control = DispatchQueue(label: "dev.beatbar.audio-control")

    init() {
        // Rebuild the tap when the output changes (e.g. headphones plugged in).
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, self.isActive else { return }
            Log.write("Output device changed; restarting audio tap")
            self.stop()
            self.start { _ in }
        }
    }

    /// Calls `completion` on the main thread with nil once audio is flowing, or the error.
    func start(completion: @escaping (Error?) -> Void) {
        guard !isActive else { return }
        isActive = true
        control.async {
            do {
                try self.createTap()
                Log.write("Audio tap started at \(Int(self.sampleRate)) Hz")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.teardown()
                DispatchQueue.main.async {
                    self.isActive = false
                    completion(error)
                }
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        control.async {
            self.teardown()
            Log.write("Audio tap stopped")
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        buffer.clear()
    }

    private func createTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format), "Reading the tap format")
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BeatBar Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "Creating the aggregate device")

        let buffer = self.buffer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let data = first.mData else { return }
            let channels = Int(max(first.mNumberChannels, 1))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            buffer.append(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
        }, "Creating the audio callback")
        try check(AudioDeviceStart(aggregateID, procID), "Starting the audio device")
    }

    private static func defaultOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
                  "Finding the output device")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = Self.address(kAudioDevicePropertyDeviceUID)
        try check(AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uid), "Reading the output device id")
        guard let uid else { throw AudioError(step: "Reading the output device id", status: -1) }
        return uid.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw AudioError(step: step, status: status) }
}

// MARK: - Turning samples into something to draw

struct AudioFrame {
    var bands: [Float]   // 0...1 loudness per frequency band, bass first
    var wave: [Float]    // -1...1 recent waveform
    var level: Float     // overall loudness 0...1
    var beat: Bool       // a kick/bass hit just happened
    var silent: Bool
}

final class SpectrumAnalyzer {
    static let bandCount = 128
    static let sampleCount = 2048

    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: sampleCount)
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var loudestRecent: Float = 0.5
    private var waveRecent: Float = 0.05
    private var bassAverage: Float = 0
    private var lastBeat = Date.distantPast
    private var quietSince: Date? = Date()
    private var idlePhase: Float = 0

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.sampleCount), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func analyze(_ samples: [Float], sampleRate: Double) -> AudioFrame {
        let n = Self.sampleCount
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))

        let now = Date()
        if rms < 0.0008 {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
        }
        if let quietSince, now.timeIntervalSince(quietSince) > 1.2 { return idleFrame() }

        // Spectrum
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samplesPointer in
                    samplesPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Log-spaced bands, 35 Hz – 16 kHz, with a treble lift so highs aren't invisible.
        let binWidth = Float(sampleRate) / Float(n)
        let low: Float = 35, high: Float = 16_000
        var targets = [Float](repeating: 0, count: Self.bandCount)
        var bass: Float = 0, bassBands: Float = 0
        for band in 0..<Self.bandCount {
            let from = low * pow(high / low, Float(band) / Float(Self.bandCount))
            let to = low * pow(high / low, Float(band + 1) / Float(Self.bandCount))
            let firstBin = min(Int(from / binWidth), n / 2 - 1)
            let lastBin = min(max(Int(to / binWidth), firstBin + 1), n / 2)
            var peak: Float = 0
            for bin in firstBin..<lastBin { peak = max(peak, magnitudes[bin]) }

            let center = (from + to) / 2
            let decibels = 20 * log10(peak / Float(n) + 1e-9) + 4.5 * log2(center / 1000)
            targets[band] = min(max((decibels + 72) / 56, 0), 1)
            if center < 140 {
                bass += targets[band]
                bassBands += 1
            }
        }
        bass /= max(bassBands, 1)

        // Auto-gain so quiet and loud songs both fill the bar.
        let loudest = targets.max() ?? 0
        loudestRecent = max(loudest, loudestRecent * 0.997)
        let gain = min(1.6, 0.92 / max(loudestRecent, 0.35))
        for band in 0..<Self.bandCount {
            let target = min(1, targets[band] * gain)
            let speed: Float = target > smoothed[band] ? 0.65 : 0.16
            smoothed[band] += (target - smoothed[band]) * speed
        }

        // Beat: bass jumping above its recent average.
        bassAverage = bassAverage * 0.93 + bass * 0.07
        var beat = false
        if bass > bassAverage * 1.22 + 0.04, bass > 0.35, now.timeIntervalSince(lastBeat) > 0.22 {
            beat = true
            lastBeat = now
        }

        // Waveform scaled to its recent peak.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(n))
        waveRecent = max(peak, waveRecent * 0.99)
        let scale = 0.95 / max(waveRecent, 0.02)
        let wave = samples.map { min(max($0 * scale, -1), 1) }

        let level = smoothed.reduce(0, +) / Float(Self.bandCount)
        return AudioFrame(bands: smoothed, wave: wave, level: level, beat: beat, silent: false)
    }

    /// A slow, dim ripple so the bar never looks dead while nothing is playing.
    private func idleFrame() -> AudioFrame {
        idlePhase += 0.025
        for band in 0..<Self.bandCount {
            let target = 0.05 + 0.07 * (sin(idlePhase * 2 + Float(band) * 0.11) + 1) / 2
            smoothed[band] += (target - smoothed[band]) * 0.08
        }
        let wave = (0..<Self.sampleCount).map { i -> Float in
            0.18 * sin(Float(i) / Float(Self.sampleCount) * .pi * 6 + idlePhase * 3)
        }
        return AudioFrame(bands: smoothed, wave: wave, level: 0, beat: false, silent: true)
    }
}
