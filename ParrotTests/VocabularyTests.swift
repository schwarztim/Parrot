import XCTest

@testable import Parrot

/// Tests the pure vocabulary replacement logic without touching the persisted
/// vocabulary file (via the static `VocabularyManager.apply(entries:to:)`).
final class VocabularyTests: XCTestCase {

    private func entries(_ pairs: [(String, String)]) -> [VocabularyEntry] {
        pairs.map { VocabularyEntry(original: $0.0, replacement: $0.1) }
    }

    private func apply(_ pairs: [(String, String)], to text: String) -> String {
        VocabularyManager.apply(entries: entries(pairs), to: text)
    }

    func testWholeWordReplacementOnly() {
        // Must not fire inside "concatenate" or "category".
        XCTAssertEqual(apply([("cat", "dog")], to: "concatenate the category"), "concatenate the category")
        XCTAssertEqual(apply([("cat", "dog")], to: "the cat sat"), "the dog sat")
    }

    func testCasePreservation() {
        XCTAssertEqual(apply([("github", "GitHub")], to: "push to github"), "push to GitHub")
        // All-caps match yields all-caps replacement.
        XCTAssertEqual(apply([("github", "GitHub")], to: "GITHUB down"), "GITHUB down")
        // Title-case match yields title-case replacement.
        XCTAssertEqual(apply([("github", "gitHub")], to: "Github outage"), "GitHub outage")
    }

    func testBoundaryAtStringEdges() {
        XCTAssertEqual(apply([("api", "API")], to: "api"), "API")
        XCTAssertEqual(apply([("api", "API")], to: "api first"), "API first")
        XCTAssertEqual(apply([("api", "API")], to: "the api"), "the API")
        // Not inside "apiary".
        XCTAssertEqual(apply([("api", "API")], to: "apiary"), "apiary")
    }

    func testPunctuationAdjacentIsWholeWord() {
        XCTAssertEqual(apply([("swift", "Swift")], to: "I love swift."), "I love Swift.")
        XCTAssertEqual(apply([("swift", "Swift")], to: "(swift)"), "(Swift)")
    }

    func testMultipleOccurrences() {
        XCTAssertEqual(apply([("cat", "dog")], to: "cat and cat"), "dog and dog")
    }
}
