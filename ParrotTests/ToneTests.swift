import XCTest

@testable import Parrot

/// The tone slider, its prompt blocks and the live example.
final class ToneTests: XCTestCase {

    func testSliderRunsCasualToFormalAndRoundTrips() {
        XCTAssertEqual(Tone.sliderOrder, [.casual, .semiCasual, .balanced, .semiFormal, .formal])
        for tone in Tone.allCases {
            XCTAssertEqual(Tone(sliderIndex: tone.sliderIndex), tone)
        }
        XCTAssertEqual(Tone(sliderIndex: -3), .casual)
        XCTAssertEqual(Tone(sliderIndex: 99), .formal)
    }

    func testBalancedHasNoBlockAndOthersOnlyAdjustForm() {
        XCTAssertNil(Tone.balanced.promptBlock)
        for tone in [Tone.casual, .semiCasual, .semiFormal, .formal] {
            let block = tone.promptBlock ?? ""
            XCTAssertTrue(block.hasPrefix("TONE: \(tone.displayName.lowercased())."), block)
            XCTAssertTrue(block.contains("never change meaning or structure"), block)
            XCTAssertTrue(block.contains("Latin alphabet"), block)
        }
    }

    func testBlocksSayWhatEachStopDoes() {
        XCTAssertTrue(Tone.formal.promptBlock!.contains("\"don't\" becomes \"do not\""))
        XCTAssertTrue(Tone.formal.promptBlock!.contains("no exclamation marks"))
        XCTAssertTrue(Tone.semiFormal.promptBlock!.contains("keep"))
        XCTAssertTrue(Tone.semiCasual.promptBlock!.contains("the word \"I\""))
        XCTAssertTrue(Tone.casual.promptBlock!.contains("everything in lowercase"))
    }

    func testLiveExamplesFollowTheirRules() {
        XCTAssertEqual(Tone.casual.example, Tone.casual.example.lowercased())
        XCTAssertFalse(Tone.casual.example.hasSuffix("."))

        XCTAssertTrue(Tone.semiCasual.example.hasPrefix("hey"))
        XCTAssertTrue(Tone.semiCasual.example.contains("I'm"))
        XCTAssertFalse(Tone.semiCasual.example.hasSuffix("."))

        XCTAssertTrue(Tone.balanced.example.hasPrefix("Hey,"))
        XCTAssertTrue(Tone.semiFormal.example.contains("going to"))
        XCTAssertTrue(Tone.semiFormal.example.contains("Don't"))

        XCTAssertTrue(Tone.formal.example.contains("I am going to"))
        XCTAssertTrue(Tone.formal.example.contains("Do not"))
        XCTAssertFalse(Tone.formal.example.contains("'"))
        XCTAssertTrue(Tone.formal.example.hasSuffix("."))
    }

    func testToneBlockSitsBetweenInstructionAndLanguageLine() {
        var mode = Mode(name: "M")
        mode.tone = .semiCasual
        mode.language = "es"
        let system = PromptRenderer.render(mode: mode).system

        let instruction = system.range(of: RefinementService.defaultDirective)!
        let tone = system.range(of: "TONE: semi-casual.")!
        let language = system.range(of: "LANGUAGE: The speaker is talking in Spanish.")!
        XCTAssertLessThan(instruction.lowerBound, tone.lowerBound)
        XCTAssertLessThan(tone.lowerBound, language.lowerBound)
    }
}
