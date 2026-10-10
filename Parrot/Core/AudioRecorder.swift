import AppKit
import AVFoundation
import CoreAudio

/// Captures microphone audio using AVAudioEngine, accumulating 16kHz mono Float32 PCM samples.
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

    private let engine = AVAudioEngine()
    private let monitorEngine = AVAudioEngine()
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16_000
    private let maxDuration: TimeInterval = 120 // 2 minutes maximum
    private let maxSampleCount = 1_920_000 // 16_000 * 120
    private var isCapturing = false

    /// True when the last recording hit the capacity cap and audio past it was
    /// dropped. Read after `stopRecording` to warn the user instead of silently
    /// truncating.
    private(set) var didReachCapacity = false

    private let bufferLock = NSLock()

    // MARK: - Initialization

    init() {
        // Pre-allocate buffer for up to 60 seconds of 16kHz audio.
        samples.reserveCapacity(maxSampleCount)
    }

    // MARK: - Recording

    /// Installs a tap on the audio engine input node and begins accumulating samples.
    ///
    /// Audio is converted to 16kHz mono Float32 if the hardware format differs.
    /// - Throws: If the audio engine cannot be started.
    func startRecording() throws {
        guard !isCapturing else { return }

        bufferLock.lock()
        samples.removeAll(keepingCapacity: true)
        currentInputLevel = 0
        didReachCapacity = false
        bufferLock.unlock()

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        // Determine the recording format. We request 16kHz mono if the engine
        // supports installing a tap in that format directly; otherwise we record
        // in the hardware format and convert in the tap callback.
        let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        let needsConversion = hardwareFormat.sampleRate != targetSampleRate
            || hardwareFormat.channelCount != 1

        // If conversion is needed, create a converter.
        var converter: AVAudioConverter?
        if needsConversion {
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
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(hardwareFormat.sampleRate * 0.1)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.processCapturedBuffer(buffer, converter: converter, desiredFormat: desiredFormat)
        }

        try engine.start()
        isCapturing = true
    }

    /// Stops recording, removes the tap, and returns accumulated 16kHz mono samples.
    ///
    /// - Returns: The recorded audio as 16kHz mono Float32 samples.
    @discardableResult
    func stopRecording() -> [Float] {
        guard isCapturing else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        bufferLock.lock()
        let result = samples
        bufferLock.unlock()

        return result
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
        let inputNode = monitorEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        diagLog("[Parrot:AudioRecorder] Monitor hardware format: rate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount)")

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            diagLog("[Parrot:AudioRecorder] startMonitoring FAILED: no valid input format")
            throw AudioRecorderError.noInputDevice
        }

        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * 0.05)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
            [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelPtr = channelData[0]
            var sumOfSquares: Float = 0
            for i in 0..<frameCount {
                let sample = channelPtr[i]
                sumOfSquares += sample * sample
            }
            let rms = sqrtf(sumOfSquares / max(Float(frameCount), 1))
            let db = 20 * log10f(max(rms, 1e-6))
            let normalized = max(0, min(1, (db + 50) / 50))
            DispatchQueue.main.async {
                self.currentInputLevel = normalized
            }
        }

        try monitorEngine.start()
        isMonitoring = true
        diagLog("[Parrot:AudioRecorder] Monitor engine started successfully")
    }

    /// Stops level monitoring and resets the level to zero.
    func stopMonitoring() {
        guard isMonitoring else { return }
        monitorEngine.inputNode.removeTap(onBus: 0)
        monitorEngine.stop()
        isMonitoring = false
        DispatchQueue.main.async {
            self.currentInputLevel = 0
        }
    }

    // MARK: - Device Enumeration

    /// Lists available audio input devices on the system.
    static func availableInputDevices() -> [InputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        let fetchStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard fetchStatus == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> InputDevice? in
            // Check if the device has input channels.
            guard hasInputChannels(deviceID) else { return nil }

            let name = deviceName(for: deviceID) ?? "Unknown Device"
            let uid = deviceUID(for: deviceID) ?? "\(deviceID)"
            return InputDevice(id: deviceID, name: name, uid: uid)
        }
    }

    // MARK: - Private Helpers

    private func processCapturedBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        desiredFormat: AVAudioFormat
    ) {
        // Compute RMS for level metering (use first channel of raw buffer).
        if let channelData = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let channelPtr = channelData[0]
            var sumOfSquares: Float = 0
            for i in 0..<frameCount {
                let sample = channelPtr[i]
                sumOfSquares += sample * sample
            }
            let rms = sqrtf(sumOfSquares / max(Float(frameCount), 1))
            currentInputLevel = min(rms, 1.0)
        }

        var outputSamples: [Float]

        if let converter {
            // Convert hardware-rate buffer to 16kHz mono.
            let ratio = desiredFormat.sampleRate / buffer.format.sampleRate
            let estimatedFrames = AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * ratio)
            )
            guard
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: desiredFormat,
                    frameCapacity: estimatedFrames + 16 // small margin
                )
            else { return }

            var error: NSError?
            var inputConsumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
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
            // Already in desired format.
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { return }
            outputSamples = Array(UnsafeBufferPointer(start: data[0], count: count))
        }

        bufferLock.lock()
        let remaining = maxSampleCount - samples.count
        if remaining > 0 {
            let toAppend = min(outputSamples.count, remaining)
            samples.append(contentsOf: outputSamples.prefix(toAppend))
            if toAppend < outputSamples.count {
                didReachCapacity = true
            }
        } else {
            didReachCapacity = true
        }
        bufferLock.unlock()
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        let fetchStatus = AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer
        )
        guard fetchStatus == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, &name
        )
        guard status == noErr else { return nil }
        return name as String
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, &uid
        )
        guard status == noErr else { return nil }
        return uid as String
    }
}

// MARK: - Errors

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case formatConversionFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device is available."
        case .formatConversionFailed:
            return "Failed to create audio format converter for 16kHz mono output."
        }
    }
}
