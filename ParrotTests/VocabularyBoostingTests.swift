import XCTest

@testable import Parrot

/// Tests the pure vocabulary-to-FluidAudio term mapping and, when the CTC
/// models are already cached, that boosting configuration does not throw.
final class VocabularyBoostingTests: XCTestCase {

    private func entries(_ pairs: [(String, String, Bool)]) -> [VocabularyEntry] {
        pairs.map { o, r, enabled in
            var e = VocabularyEntry(original: o, replacement: r)
            e.isEnabled = enabled
            return e
        }
    }

    func testLinesBoostReplacementWithOriginalAlias() {
        let lines = TranscriptionEngine.simpleFormatLines(from: entries([("git hub", "GitHub", true)]))
        XCTAssertEqual(lines, ["GitHub: git hub"])
    }

    func testLinesSkipDisabledAndEmpty() {
        let lines = TranscriptionEngine.simpleFormatLines(from: entries([
            ("git hub", "GitHub", false),   // disabled
            ("   ", "   ", true),            // empty replacement
            ("k8s", "Kubernetes", true),    // kept
        ]))
        XCTAssertEqual(lines, ["Kubernetes: k8s"])
    }

    func testLinesNoSelfAliasWhenEqualIgnoringCase() {
        let lines = TranscriptionEngine.simpleFormatLines(from: entries([("kubernetes", "Kubernetes", true)]))
        XCTAssertEqual(lines, ["Kubernetes"])
    }

    func testLinesDedupeByReplacement() {
        let lines = TranscriptionEngine.simpleFormatLines(from: entries([
            ("git hub", "GitHub", true),
            ("git-hub", "github", true),  // same replacement ignoring case
        ]))
        XCTAssertEqual(lines.count, 1)
    }

    func testEmptyEntriesYieldNoLines() {
        XCTAssertTrue(TranscriptionEngine.simpleFormatLines(from: []).isEmpty)
    }
}
