import XCTest

@testable import Parrot

/// Adaptive waveform normalization: gain, envelope and speech hold.
final class WaveformNormalizerTests: XCTestCase {

    func testGainStartsAtOne() {
        XCTAssertEqual(WaveformNormalizer().adaptiveGain, 1)
    }

    func testQuietSpeechGrowsToFillTheBars() {
        var normalizer = WaveformNormalizer()
        var level: Float = 0
        for _ in 0..<60 {
            level = normalizer.normalize(peak: 0.05)
        }
        XCTAssertGreaterThan(normalizer.adaptiveGain, 10)
        XCTAssertEqual(level, 0.9, accuracy: 0.1)
    }

    func testLoudSpeechIsNotAmplified() {
        var normalizer = WaveformNormalizer()
        for _ in 0..<30 {
            XCTAssertLessThanOrEqual(normalizer.normalize(peak: 1), 1)
        }
        XCTAssertEqual(normalizer.adaptiveGain, 1, accuracy: 0.01)
    }

    func testRoomNoiseStaysLow() {
        var normalizer = WaveformNormalizer()
        var level: Float = 0
        for _ in 0..<100 {
            level = normalizer.normalize(peak: 0.001)
        }
        XCTAssertLessThan(level, 0.05)
    }

    func testSpeechHoldSlowsTheDropBetweenWords() {
        var held = WaveformNormalizer()
        for _ in 0..<20 { _ = held.normalize(peak: 0.5) }
        let speaking = held.normalize(peak: 0.5)
        let firstSilent = held.normalize(peak: 0)
        XCTAssertGreaterThan(firstSilent, speaking * 0.85, "held right after a word")

        for _ in 0..<WaveformNormalizer.speechHoldUpdates + 6 {
            _ = held.normalize(peak: 0)
        }
        XCTAssertLessThan(held.normalize(peak: 0), 0.1, "decays once the hold ends")
    }

    func testOutputStaysInRangeForOddInput() {
        var normalizer = WaveformNormalizer()
        for peak: Float in [.nan, .infinity, -1, 3, 0.2] {
            let level = normalizer.normalize(peak: peak)
            XCTAssertTrue(level >= 0 && level <= 1, "level \(level) for \(peak)")
        }
    }

    func testPeakHistoryForgetsOldLoudness() {
        var normalizer = WaveformNormalizer()
        for _ in 0..<10 { _ = normalizer.normalize(peak: 1) }
        for _ in 0..<(WaveformNormalizer.peakHistorySize + 40) { _ = normalizer.normalize(peak: 0.1) }
        XCTAssertGreaterThan(normalizer.adaptiveGain, 7, "an old shout no longer caps the gain")
    }
}
