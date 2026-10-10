import XCTest

@testable import Parrot

/// Which cue plays for each event and theme, and that the synthesized cues
/// are distinct and safe to play. Never plays a sound.
final class CueSelectionTests: XCTestCase {

    func testSimpleTheme() {
        XCTAssertEqual(CueSelection.cue(for: .start, theme: .simple, enabled: true), .start)
        XCTAssertEqual(CueSelection.cue(for: .stop, theme: .simple, enabled: true), .stop)
    }

    func testClassicTheme() {
        XCTAssertEqual(CueSelection.cue(for: .start, theme: .classic, enabled: true), .startClassic)
        XCTAssertEqual(CueSelection.cue(for: .stop, theme: .classic, enabled: true), .stopClassic)
    }

    func testEmptyOutcomePlaysNoResultInBothThemes() {
        for theme in SoundTheme.allCases {
            XCTAssertEqual(CueSelection.cue(for: .finish(.empty), theme: theme, enabled: true), .noResult)
        }
    }

    func testOtherOutcomesPlayNothingAtFinish() {
        for outcome: DictationOutcome in [.pasted, .copiedOnly, .discarded, .routedToAgent, .failed("x")] {
            XCTAssertNil(CueSelection.cue(for: .finish(outcome), theme: .simple, enabled: true))
        }
    }

    func testOffPlaysNothing() {
        for event: CueEvent in [.start, .stop, .finish(.empty)] {
            XCTAssertNil(CueSelection.cue(for: event, theme: .classic, enabled: false))
        }
    }

    func testSynthesizedCuesHaveSpecLengthsAndSafePeaks() {
        let rate = ToneSynth.sampleRate
        let lengths = Dictionary(uniqueKeysWithValues: SoundCue.allCases.map { cue in
            (cue, Double(ToneSynth.render(cue).count) / rate)
        })
        XCTAssertEqual(lengths[.start]!, 0.33, accuracy: 0.05)
        XCTAssertEqual(lengths[.stop]!, 0.33, accuracy: 0.05)
        XCTAssertEqual(lengths[.noResult]!, 0.6, accuracy: 0.05)
        XCTAssertEqual(lengths[.startClassic]!, 1.14, accuracy: 0.05)
        XCTAssertEqual(lengths[.stopClassic]!, 1.14, accuracy: 0.05)

        for cue in SoundCue.allCases {
            let samples = ToneSynth.render(cue)
            let peak = samples.map(abs).max() ?? 0
            XCTAssertEqual(peak, 0.8, accuracy: 0.001, "\(cue) peak")
            XCTAssertLessThan(abs(samples.first ?? 1), 0.01, "\(cue) starts without a click")
            XCTAssertLessThan(abs(samples.last ?? 1), 0.01, "\(cue) ends without a click")
        }
    }

    func testStartAndStopCuesDiffer() {
        XCTAssertNotEqual(ToneSynth.render(.start), ToneSynth.render(.stop))
        XCTAssertNotEqual(ToneSynth.render(.startClassic), ToneSynth.render(.stopClassic))
    }
}
