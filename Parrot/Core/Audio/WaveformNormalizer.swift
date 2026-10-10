import Foundation

/// Turns raw buffer peaks into waveform bar heights (au F20). The gain
/// adapts to the speaker over the last 100 peaks, so quiet and loud voices
/// both fill the bars; an envelope with a short speech hold keeps the bars
/// from collapsing between words. [AUD]
struct WaveformNormalizer {
    static let peakHistorySize = 100
    /// Peaks below this never count as the loudest recent sound, so room
    /// noise is not amplified to full height.
    static let noiseFloor: Float = 0.02
    static let maxGain: Float = 20
    /// The loudest recent peak maps to this height.
    static let targetLevel: Float = 0.9
    /// Normalized levels above this count as speech and start the hold.
    static let speechThreshold: Float = 0.15
    /// Updates (at 20 Hz) the envelope decays slowly after speech.
    static let speechHoldUpdates = 4

    private(set) var adaptiveGain: Float = 1
    private var peaks: [Float] = []
    private var nextPeakIndex = 0
    private var envelope: Float = 0
    private var speechHold = 0

    /// Feeds one peak (absolute sample value, 0 to 1) and returns the bar
    /// height, 0 to 1.
    mutating func normalize(peak rawPeak: Float) -> Float {
        let peak = rawPeak.isFinite ? min(max(rawPeak, 0), 1) : 0
        remember(peak)

        let loudest = max(peaks.max() ?? 0, Self.noiseFloor)
        let wantedGain = min(max(Self.targetLevel / loudest, 1), Self.maxGain)
        // Rise slowly, fall fast: a sudden loud word must not clip for long.
        let rate: Float = wantedGain < adaptiveGain ? 0.5 : 0.1
        adaptiveGain += (wantedGain - adaptiveGain) * rate

        let level = min(peak * adaptiveGain, 1)
        if level >= Self.speechThreshold {
            speechHold = Self.speechHoldUpdates
        }
        if level >= envelope {
            envelope = level
        } else if speechHold > 0 {
            speechHold -= 1
            envelope = max(level, envelope * 0.92)
        } else {
            envelope = max(level, envelope * 0.6)
        }
        return envelope
    }

    mutating func reset() {
        self = WaveformNormalizer()
    }

    private mutating func remember(_ peak: Float) {
        if peaks.count < Self.peakHistorySize {
            peaks.append(peak)
        } else {
            peaks[nextPeakIndex] = peak
            nextPeakIndex = (nextPeakIndex + 1) % Self.peakHistorySize
        }
    }
}

/// The "No Audio Detected" check (au F19): if the first 3 s of a recording
/// never peak at 0.0018 or above, warn; once warned, any louder buffer
/// clears it. Time is measured in captured audio, so the check is
/// deterministic. [AUD]
struct SilentMicDetector {
    static let window: TimeInterval = 3.0
    static let threshold: Float = 0.0018

    enum Change: Equatable {
        case warn
        case clear
    }

    private(set) var maxPeak: Float = 0
    private(set) var isWarning = false
    private var windowClosed = false

    /// Feeds one buffer's peak; `endTime` is the buffer's end in seconds
    /// since the recording started.
    mutating func process(peak: Float, endTime: TimeInterval) -> Change? {
        if !windowClosed {
            maxPeak = max(maxPeak, peak)
            guard endTime >= Self.window else { return nil }
            windowClosed = true
            if maxPeak < Self.threshold {
                isWarning = true
                return .warn
            }
            return nil
        }
        if isWarning, peak >= Self.threshold {
            isWarning = false
            return .clear
        }
        return nil
    }

    mutating func reset() {
        self = SilentMicDetector()
    }
}
