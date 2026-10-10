import Foundation

/// A frame sink that turns captured audio into waveform levels, one per
/// 50 ms of audio (20 per second, au F20), and runs the silent mic check
/// (au F19). Runs on the audio thread and hands results to `publish`,
/// which must hop to the main thread itself. [AUD]
final class LevelMeter: AudioFrameSink, @unchecked Sendable {

    /// 50 ms at 16 kHz.
    static let samplesPerLevel = 800

    enum Event: Equatable {
        /// New normalized levels, oldest first.
        case levels([Float])
        /// True when the first 3 s were silent; false once real audio arrives.
        case silentMic(Bool)
    }

    private let lock = NSLock()
    private var normalizer = WaveformNormalizer()
    private var detector = SilentMicDetector()
    private var chunkPeak: Float = 0
    private var chunkFill = 0
    private let publish: ([Event]) -> Void

    init(publish: @escaping ([Event]) -> Void) {
        self.publish = publish
    }

    func consume(_ frame: AudioFrame) {
        var levels: [Float] = []
        var events: [Event] = []

        lock.lock()
        var framePeak: Float = 0
        for sample in frame.samples {
            let magnitude = abs(sample)
            framePeak = max(framePeak, magnitude)
            chunkPeak = max(chunkPeak, magnitude)
            chunkFill += 1
            if chunkFill >= Self.samplesPerLevel {
                levels.append(normalizer.normalize(peak: chunkPeak))
                chunkPeak = 0
                chunkFill = 0
            }
        }
        let endTime = Double(frame.startSample + frame.samples.count) / AudioFrame.sampleRate
        let change = detector.process(peak: framePeak, endTime: endTime)
        lock.unlock()

        if !levels.isEmpty { events.append(.levels(levels)) }
        if let change { events.append(.silentMic(change == .warn)) }
        if !events.isEmpty { publish(events) }
    }
}
