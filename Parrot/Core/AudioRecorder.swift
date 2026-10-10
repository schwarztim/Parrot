import AppKit
import AVFoundation
import CoreAudio

/// Audio mixed into each captured buffer before it is stored and fanned
/// out (system audio for meeting modes). Runs on the audio thread. [AUD]
protocol AudioMixSource: AnyObject, Sendable {
    /// Adds pending audio into `samples` (16 kHz mono) in place.
    func mix(into samples: inout [Float])
}

/// Why the recorder is asking for an input device.
enum CapturePurpose: Sendable {
    /// A recording is starting.
    case recording
    /// A running recording moves to a new device or recovers.
    case restart
    /// The settings level meter (nothing is recorded).
    case monitoring
}

/// Captures microphone audio using AVAudioEngine, accumulating 16kHz mono Float32 PCM samples.
///
/// Capture runs on the device `deviceProvider` picks (AudioDeviceService
/// installs it). All channels are summed to mono. Recordings have no length
/// limit. A watchdog restarts capture when callbacks stop for 3 s, and
/// `restartCapture(reason:)` moves capture to a newly picked device while
/// keeping the samples so far. Start, stop and restart run on the main
/// thread; buffers arrive on the audio thread.
final class AudioRecorder {

    // MARK: - Types

    struct InputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
    }

    // MARK: - Properties

    /// Current RMS input level (0...1) for waveform visualization.
    private(set) var currentInputLevel: Float = 0

    /// True when monitoring input level without recording.
    private(set) var isMonitoring = false

    /// Picks the input device each time capture or monitoring starts or
    /// restarts. Nil (or a nil result) uses the engine's default input.
    var deviceProvider: (@MainActor (CapturePurpose) -> AudioDevice?)?

    /// The device the running capture uses; nil when it uses the engine's
    /// default input.
    private(set) var currentDevice: AudioDevice?

    var isRecording: Bool { isCapturing }

    /// Always false: recordings have no length limit (au F26). Kept for
    /// `AudioCapturing`.
    private(set) var didReachCapacity = false

    /// Watchdog constants (au F8).
    static let healthCheckInterval: TimeInterval = 2.0
    static let maxCallbackGap: TimeInterval = 3.0

    /// Times capture was restarted this launch (device change or watchdog).
    private(set) var recoveryAttempts = 0

    private var engine: AVAudioEngine?
    private var monitorEngine: AVAudioEngine?
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16_000
    private var isCapturing = false
    private var watchdog: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var lastRestartTime: CFAbsoluteTime = 0

    /// Guards `samples`, `currentInputLevel` writes and `lastCallbackTime`.
    private let bufferLock = NSLock()
    private var lastCallbackTime: CFAbsoluteTime = 0

    /// Receivers of every captured buffer and the mix source, guarded by `sinkLock`.
    private var sinks: [AudioFrameSink] = []
    private var mixSource: AudioMixSource?
    /// Samples fanned out since the current recording started.
    private var emittedSampleCount = 0
    private let sinkLock = NSLock()

    // MARK: - Initialization

    init() {
        // Room for two minutes of 16 kHz audio; longer recordings grow it.
        samples.reserveCapacity(1_920_000)
    }

    // MARK: - Recording

    /// Opens the picked input device and begins accumulating samples.
    ///
    /// Audio is summed to mono and converted to 16kHz Float32.
    /// - Throws: If permission is denied or the device cannot start.
    func startRecording() throws {
        guard !isCapturing else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            diagLog("[Parrot:AudioRecorder] Does not have microphone access")
            throw AudioRecorderError.permissionDenied
        default:
            break
        }

        bufferLock.lock()
        samples.removeAll(keepingCapacity: true)
        currentInputLevel = 0
        lastCallbackTime = CFAbsoluteTimeGetCurrent()
        bufferLock.unlock()

        sinkLock.lock()
        emittedSampleCount = 0
        sinkLock.unlock()

        try startCaptureEngine(purpose: .recording)
        isCapturing = true
        startWatchdog()
    }

    /// Stops recording, removes the tap, and returns accumulated 16kHz mono samples.
    ///
    /// - Returns: The recorded audio as 16kHz mono Float32 samples.
    @discardableResult
    func stopRecording() -> [Float] {
        guard isCapturing else { return [] }

        stopWatchdog()
        stopCaptureEngine()
        isCapturing = false

        bufferLock.lock()
        let result = samples
        bufferLock.unlock()

        return result
    }

    /// Restarts capture on the device the provider picks now, keeping the
    /// samples so far. AudioDeviceService calls it when the device changes
    /// mid-recording; the watchdog calls it when callbacks stop.
    func restartCapture(reason: String) {
        guard isCapturing else { return }
        recoveryAttempts += 1
        lastRestartTime = CFAbsoluteTimeGetCurrent()
        stopCaptureEngine()
        do {
            try startCaptureEngine(purpose: .restart)
            bufferLock.lock()
            lastCallbackTime = CFAbsoluteTimeGetCurrent()
            bufferLock.unlock()
            diagLog("[Parrot:AudioRecorder] Capture restarted (\(reason)) on \(currentDevice?.name ?? "default input")")
        } catch {
            // The watchdog tries again on its next check.
            diagLog("[Parrot:AudioRecorder] Capture restart failed (\(reason)): \(error)")
        }
    }

    // MARK: - Frame Sinks

    /// Registers a receiver for every captured buffer, converted to 16 kHz
    /// mono Float32, while recording. Frames arrive on the audio thread.
    /// The recorder keeps a strong reference until `removeSink(_:)`.
    func addSink(_ sink: AudioFrameSink) {
        sinkLock.lock()
        if !sinks.contains(where: { $0 === sink }) {
            sinks.append(sink)
        }
        sinkLock.unlock()
    }

    /// Stops sending frames to `sink`.
    func removeSink(_ sink: AudioFrameSink) {
        sinkLock.lock()
        sinks.removeAll { $0 === sink }
        sinkLock.unlock()
    }

    /// Mixes `source` into every buffer from now on; nil stops mixing.
    func setMixSource(_ source: AudioMixSource?) {
        sinkLock.lock()
        mixSource = source
        sinkLock.unlock()
    }

    // MARK: - Level Monitoring (no recording)

    /// Installs a tap that updates `currentInputLevel` without accumulating samples.
    /// Use this for real-time audio level visualization in the Sound settings.
    func startMonitoring() throws {
        guard !isMonitoring, !isCapturing else {
            diagLog("[Parrot:AudioRecorder] startMonitoring skipped: isMonitoring=\(isMonitoring), isCapturing=\(isCapturing)")
            return
        }

        // Accessing inputNode triggers the mic permission prompt. This must not
        // activate Parrot: the meter can resume right after a dictation's
        // paste, and stealing focus would race the Cmd+V. The onboarding mic
        // step brings its window forward itself.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let device = resolveDevice(for: .monitoring) {
            _ = Self.select(device, on: inputNode)
        }
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        diagLog("[Parrot:AudioRecorder] Monitor hardware format: rate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount)")

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            diagLog("[Parrot:AudioRecorder] startMonitoring FAILED: no valid input format")
            throw AudioRecorderError.noInputDevice
        }

        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * 0.05)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
            [weak self] buffer, _ in
            guard let self, let mono = Self.downmixToMono(buffer) else { return }
            let normalized = Self.meterLevel(rms: Self.rms(mono))
            DispatchQueue.main.async {
                self.currentInputLevel = normalized
            }
        }

        try engine.start()
        monitorEngine = engine
        isMonitoring = true
        diagLog("[Parrot:AudioRecorder] Monitor engine started successfully")
    }

    /// Stops level monitoring and resets the level to zero.
    func stopMonitoring() {
        guard isMonitoring else { return }
        monitorEngine?.inputNode.removeTap(onBus: 0)
        monitorEngine?.stop()
        monitorEngine = nil
        isMonitoring = false
        DispatchQueue.main.async {
            self.currentInputLevel = 0
        }
    }

    // MARK: - Device Enumeration

    /// Lists available audio input devices on the system.
    static func availableInputDevices() -> [InputDevice] {
        CoreAudioHardware().inputDevices().map { InputDevice(id: $0.id, name: $0.name, uid: $0.uid) }
    }

    // MARK: - Buffer Processing

    /// Sums one tap buffer to mono, converts it to 16 kHz, mixes in the mix
    /// source, fans it out to the sinks and appends it to the recording.
    /// Internal so tests can feed buffers.
    func processCapturedBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        desiredFormat: AVAudioFormat
    ) {
        bufferLock.lock()
        lastCallbackTime = CFAbsoluteTimeGetCurrent()
        bufferLock.unlock()

        guard let mono = Self.downmixToMono(buffer) else { return }
        currentInputLevel = min(Self.rms(mono), 1.0)

        var outputSamples: [Float]

        if let converter {
            // Convert hardware-rate buffer to 16kHz mono. `.noDataNow` keeps
            // the resampler's state between buffers, so joins are seamless.
            let ratio = desiredFormat.sampleRate / mono.format.sampleRate
            let estimatedFrames = AVAudioFrameCount(
                ceil(Double(mono.frameLength) * ratio)
            )
            guard
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: desiredFormat,
                    frameCapacity: estimatedFrames + 64 // small margin
                )
            else { return }

            var error: NSError?
            var inputConsumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return mono
            }

            let conversionStatus = converter.convert(
                to: convertedBuffer,
                error: &error,
                withInputFrom: inputBlock
            )

            guard conversionStatus != .error, error == nil else { return }

            let count = Int(convertedBuffer.frameLength)
            guard count > 0, let data = convertedBuffer.floatChannelData else { return }
            outputSamples = Array(UnsafeBufferPointer(start: data[0], count: count))
        } else {
            // Already 16 kHz.
            let count = Int(mono.frameLength)
            guard count > 0, let data = mono.floatChannelData else { return }
            outputSamples = Array(UnsafeBufferPointer(start: data[0], count: count))
        }

        sinkLock.lock()
        let mixer = mixSource
        sinkLock.unlock()
        mixer?.mix(into: &outputSamples)

        fanOut(outputSamples)

        bufferLock.lock()
        samples.append(contentsOf: outputSamples)
        bufferLock.unlock()
    }

    /// Sums every channel into one, clamped to -1...1 (au F10). A mono
    /// non-interleaved buffer is returned as is; nil for non-float buffers.
    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, let data = buffer.floatChannelData else { return nil }
        if channels == 1, !buffer.format.isInterleaved { return buffer }

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false
            ),
            let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        guard let out = mono.floatChannelData?[0] else { return nil }

        if buffer.format.isInterleaved {
            let interleaved = data[0]
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved[frame * channels + channel]
                }
                out[frame] = min(max(sum, -1), 1)
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += data[channel][frame]
                }
                out[frame] = min(max(sum, -1), 1)
            }
        }
        return mono
    }

    // MARK: - Private Helpers

    private func startCaptureEngine(purpose: CapturePurpose) throws {
        let device = resolveDevice(for: purpose)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var applied: AudioDevice?
        if let device, Self.select(device, on: inputNode) {
            applied = device
        }

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // Buffers are summed to mono first, so the converter only resamples.
        var converter: AVAudioConverter?
        if hardwareFormat.sampleRate != targetSampleRate {
            let monoFloat32Hardware = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            converter = AVAudioConverter(from: monoFloat32Hardware, to: desiredFormat)
            guard converter != nil else {
                throw AudioRecorderError.formatConversionFailed
            }
        }

        // Buffer size: ~100ms of audio at hardware sample rate.
        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * 0.1)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
            [weak self] buffer, _ in
            self?.processCapturedBuffer(buffer, converter: converter, desiredFormat: desiredFormat)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            diagLog("[Parrot:AudioRecorder] Engine start failed: \(error)")
            throw AudioRecorderError.startFailed
        }

        // The engine stops itself when its device's format changes or the
        // device goes away; restart on whatever the provider picks then.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, CFAbsoluteTimeGetCurrent() - self.lastRestartTime > 0.5 else { return }
            self.restartCapture(reason: "engine configuration change")
        }

        self.engine = engine
        currentDevice = applied
        diagLog("[Parrot:AudioRecorder] Capture started on \(applied?.name ?? "default input"): rate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount)")
    }

    private func stopCaptureEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func resolveDevice(for purpose: CapturePurpose) -> AudioDevice? {
        guard let deviceProvider, Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { deviceProvider(purpose) }
    }

    /// Points the input node at `device` and reads it back to verify.
    private static func select(_ device: AudioDevice, on inputNode: AVAudioInputNode) -> Bool {
        guard let unit = inputNode.audioUnit else { return false }
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, size
        )
        guard status == noErr else {
            diagLog("[Parrot:AudioRecorder] Could not select input device \(device.name): \(status)")
            return false
        }
        var applied = AudioDeviceID(0)
        var readSize = size
        let readStatus = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &applied, &readSize
        )
        guard readStatus == noErr, applied == device.id else {
            diagLog("[Parrot:AudioRecorder] Device ID verification failed for \(device.name)")
            return false
        }
        return true
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkHealth() {
        guard isCapturing else { return }
        bufferLock.lock()
        let gap = CFAbsoluteTimeGetCurrent() - lastCallbackTime
        bufferLock.unlock()
        guard Self.needsRestart(callbackGap: gap) else { return }
        diagLog("[Parrot:AudioRecorder] Audio health check: No callbacks for \(String(format: "%.1f", gap))s, attempting restart")
        restartCapture(reason: "health check")
    }

    static func needsRestart(callbackGap: TimeInterval) -> Bool {
        callbackGap > maxCallbackGap
    }

    /// Sends converted samples to every sink, on the calling (audio) thread.
    private func fanOut(_ samples: [Float]) {
        sinkLock.lock()
        let receivers = sinks
        let startSample = emittedSampleCount
        emittedSampleCount += samples.count
        sinkLock.unlock()

        guard !receivers.isEmpty else { return }
        let frame = AudioFrame(samples: samples, startSample: startSample)
        for sink in receivers {
            sink.consume(frame)
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for i in 0..<frameCount {
            sumOfSquares += data[i] * data[i]
        }
        return sqrtf(sumOfSquares / max(Float(frameCount), 1))
    }

    /// Maps RMS onto 0...1 over a 50 dB range for the settings meter.
    private static func meterLevel(rms: Float) -> Float {
        let db = 20 * log10f(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }
}

// MARK: - Pipeline

extension AudioRecorder: AudioCapturing {}

// MARK: - Errors

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case formatConversionFailed
    case permissionDenied
    case startFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "The audio device is not available or in use by another application. Please check your device settings and try again."
        case .formatConversionFailed:
            return "Failed to create audio format converter for 16kHz mono output."
        case .permissionDenied:
            return "Permission to record audio with device was not granted. Please allow access in your device settings and try again."
        case .startFailed:
            return "Could not start recording. Please check your device settings and try again."
        }
    }
}
