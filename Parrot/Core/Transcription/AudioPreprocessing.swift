import Foundation

// MARK: - Time Map

/// Where the kept speech came from in the original recording, so times in
/// the trimmed audio map back to recording time. [ASR]
struct SpeechTimeMap: Equatable, Sendable {
    /// One kept stretch: `length` samples copied from `originalStart` to
    /// `trimmedStart`.
    struct Piece: Equatable, Sendable {
        let originalStart: Int
        let trimmedStart: Int
        let length: Int
    }

    let pieces: [Piece]
    let originalCount: Int

    var trimmedCount: Int { pieces.last.map { $0.trimmedStart + $0.length } ?? 0 }

    /// Seconds of kept audio.
    var keptSeconds: TimeInterval { Double(trimmedCount) / AudioFrame.sampleRate }

    /// Maps a time in the trimmed audio to recording time. A time past the
    /// trimmed end keeps its overshoot, so "past the end" stays detectable.
    func originalTime(_ trimmedTime: TimeInterval) -> TimeInterval {
        let sample = Int((trimmedTime * AudioFrame.sampleRate).rounded())
        guard let first = pieces.first else { return trimmedTime }
        if sample <= first.trimmedStart {
            return Double(first.originalStart) / AudioFrame.sampleRate
        }
        let piece = pieces.last { $0.trimmedStart <= sample } ?? first
        let original = piece.originalStart + (sample - piece.trimmedStart)
        if piece == pieces.last, sample > trimmedCount {
            // Past the trimmed end: anchor to the original end, keep the overshoot.
            return Double(originalCount + (sample - trimmedCount)) / AudioFrame.sampleRate
        }
        return Double(original) / AudioFrame.sampleRate
    }

    func mapSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            var mapped = segment
            mapped.start = originalTime(segment.start)
            mapped.end = max(mapped.start, originalTime(segment.end))
            return mapped
        }
    }
}

// MARK: - Silence Removal

/// Cuts silence out of a recording, keeping the speech regions. [ASR]
enum SilenceTrimmer {
    /// Merges overlapping regions, clamps them to the audio and joins the
    /// speech. Returns the joined audio and its time map.
    static func trim(_ samples: [Float], keeping regions: [Range<Int>]) -> (samples: [Float], map: SpeechTimeMap) {
        let merged = merge(regions, limit: samples.count)
        var output: [Float] = []
        output.reserveCapacity(merged.reduce(0) { $0 + $1.count })
        var pieces: [SpeechTimeMap.Piece] = []
        for region in merged {
            pieces.append(SpeechTimeMap.Piece(
                originalStart: region.lowerBound, trimmedStart: output.count, length: region.count
            ))
            output.append(contentsOf: samples[region])
        }
        return (output, SpeechTimeMap(pieces: pieces, originalCount: samples.count))
    }

    /// Sorted, non-overlapping regions inside `0..<limit`.
    static func merge(_ regions: [Range<Int>], limit: Int) -> [Range<Int>] {
        let clamped = regions
            .map { max(0, $0.lowerBound)..<min(limit, $0.upperBound) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for region in clamped {
            if let last = merged.last, region.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, region.upperBound)
            } else {
                merged.append(region)
            }
        }
        return merged
    }
}

// MARK: - Short-Clip Gate

/// Skips short recordings with no speech, so a blank press never turns
/// into invented text. [ASR]
enum ShortClipGate {
    /// Recordings up to this long are checked.
    static let maxDuration: TimeInterval = 5

    /// True when the clip is short and the detector found no speech.
    static func shouldSkip(duration: TimeInterval, speechSamples: Int) -> Bool {
        duration <= maxDuration && speechSamples == 0
    }
}

// MARK: - Normalization

/// Evens out loudness before transcription: removes low rumble, then
/// raises or lowers each half second toward a target level with smooth
/// gain changes and a soft peak limit. Silence is never boosted. [ASR]
enum AudioNormalizer {
    /// About -20 dBFS.
    static let targetRMS: Float = 0.1
    static let maxGain: Float = 10
    static let minGain: Float = 0.5
    /// Windows quieter than this are treated as silence and left alone.
    static let silenceRMS: Float = 0.002
    static let windowSamples = 8_000
    /// Corner of the rumble filter.
    static let highPassHz: Float = 70

    static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let filtered = highPass(samples)

        // One gain per window, from that window's level.
        let windowCount = (filtered.count + windowSamples - 1) / windowSamples
        var gains = [Float](repeating: 1, count: windowCount)
        for w in 0..<windowCount {
            let start = w * windowSamples
            let end = min(filtered.count, start + windowSamples)
            var sum: Float = 0
            for i in start..<end { sum += filtered[i] * filtered[i] }
            let rms = (sum / Float(end - start)).squareRoot()
            gains[w] = rms < silenceRMS ? 1 : min(maxGain, max(minGain, targetRMS / rms))
        }

        // Interpolate between window centers so the gain never jumps.
        var output = [Float](repeating: 0, count: filtered.count)
        let half = Float(windowSamples) / 2
        for i in 0..<filtered.count {
            let position = (Float(i) - half) / Float(windowSamples)
            let lower = max(0, min(windowCount - 1, Int(position.rounded(.down))))
            let upper = min(windowCount - 1, lower + 1)
            let fraction = max(0, min(1, position - Float(lower)))
            let gain = gains[lower] + (gains[upper] - gains[lower]) * fraction
            output[i] = softLimit(filtered[i] * gain)
        }
        return output
    }

    /// One-pole high-pass filter.
    static func highPass(_ samples: [Float]) -> [Float] {
        let rc = 1 / (2 * Float.pi * highPassHz)
        let dt = 1 / Float(AudioFrame.sampleRate)
        let alpha = rc / (rc + dt)
        var output = [Float](repeating: 0, count: samples.count)
        var previousIn = samples[0]
        var previousOut: Float = 0
        for i in 0..<samples.count {
            let value = alpha * (previousOut + samples[i] - previousIn)
            output[i] = value
            previousIn = samples[i]
            previousOut = value
        }
        return output
    }

    /// Leaves samples under 0.9 alone and bends louder ones toward 1.
    static func softLimit(_ x: Float) -> Float {
        let knee: Float = 0.9
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let over = magnitude - knee
        let limited = knee + (1 - knee) * (over / (over + (1 - knee)))
        return x < 0 ? -limited : limited
    }
}
