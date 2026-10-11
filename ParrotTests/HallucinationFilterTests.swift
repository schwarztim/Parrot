import XCTest

@testable import Parrot

/// Parrot's hallucination list, segments past the audio end, and the
/// cleanup stage's empty result.
@MainActor
final class HallucinationFilterTests: XCTestCase {

    func testStockPhrasesAreDroppedWhateverTheCaseAndPunctuation() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Thanks for watching!", speechSeconds: nil))
        XCTAssertTrue(HallucinationFilter.isHallucination("  PLEASE SUBSCRIBE.  ", speechSeconds: 2))
        XCTAssertTrue(HallucinationFilter.isHallucination("Subtitles by the Amara.org community", speechSeconds: nil))
    }

    func testTagOnlyTranscriptsAreDropped() {
        XCTAssertTrue(HallucinationFilter.isHallucination("[BLANK_AUDIO]", speechSeconds: nil))
        XCTAssertTrue(HallucinationFilter.isHallucination("(upbeat music)", speechSeconds: nil))
        XCTAssertTrue(HallucinationFilter.isHallucination("♪ ♪", speechSeconds: nil))
    }

    func testCreditLinesMatchByOpeningWords() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Closed captions by Jane Example.", speechSeconds: nil))
        XCTAssertTrue(HallucinationFilter.isHallucination("Transcribed by an example service", speechSeconds: 3))
    }

    func testRealDictationContainingAPhraseIsKept() {
        XCTAssertFalse(HallucinationFilter.isHallucination(
            "Thanks for watching the kids last night, see you Friday.", speechSeconds: 3
        ))
        XCTAssertFalse(HallucinationFilter.isHallucination("Hello world, this is a test.", speechSeconds: nil))
        // A credit-like opening in a long message is real speech.
        XCTAssertFalse(HallucinationFilter.isHallucination(
            "Subtitles by default should be turned on for every video we publish on the site from now on",
            speechSeconds: 4
        ))
    }

    func testShortPhrasesDropOnlyWhenTheDetectorHeardNoSpeech() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Thank you.", speechSeconds: 0.1))
        XCTAssertFalse(HallucinationFilter.isHallucination("Thank you.", speechSeconds: 1.2))
        XCTAssertFalse(HallucinationFilter.isHallucination("Thank you.", speechSeconds: nil))
    }

    func testSegmentsStartingAfterTheEndAreDropped() {
        let segments = [
            TranscriptSegment(text: "Real words.", start: 0.2, end: 1.8),
            TranscriptSegment(text: "Invented.", start: 3.4, end: 4.0),
        ]
        let (kept, dropped) = HallucinationFilter.dropSegmentsPastEnd(segments, duration: 3.0)
        XCTAssertEqual(kept.map(\.text), ["Real words."])
        XCTAssertEqual(dropped, 1)
    }

    // MARK: - Stage

    func testStageFinishesEmptyOnAHallucination() async throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let session = env.session(samples: ASRFixture.zeros(seconds: 2))
        session.text = "Thanks for watching!"
        session.rawTranscript = session.text

        let result = try await TranscriptCleanupStage(services: env.services).run(session)

        XCTAssertEqual(result, .finish(.empty))
        XCTAssertEqual(session.text, "")
        XCTAssertEqual(session.rawTranscript, "Thanks for watching!", "the raw transcript is kept")
    }

    func testStageRebuildsTextWithoutSegmentsPastTheEnd() async throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let session = env.session(samples: ASRFixture.zeros(seconds: 3))
        session.text = "Real words. Invented."
        session.segments = [
            TranscriptSegment(text: "Real words.", start: 0.2, end: 1.8),
            TranscriptSegment(text: "Invented.", start: 3.5, end: 4.0),
        ]

        let result = try await TranscriptCleanupStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
        XCTAssertEqual(session.text, "Real words.")
        XCTAssertEqual(session.segments.count, 1)
    }

    func testStageFinishesEmptyOnBlankText() async throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let session = env.session(samples: ASRFixture.zeros(seconds: 1))
        session.text = "   "

        let result = try await TranscriptCleanupStage(services: env.services).run(session)

        XCTAssertEqual(result, .finish(.empty))
    }
}
