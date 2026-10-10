import XCTest

@testable import Parrot

/// Full-text search uses FTS5 with the Porter stemmer over unicode61, across
/// raw, LLM and final text, plus prefix matching while typing.
final class StemmingSearchTests: XCTestCase {

    private var dbURL: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-stem-\(UUID().uuidString).db")
        store = try HistoryStore(databaseURL: dbURL)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    private func add(raw: String, final: String? = nil, llm: String? = nil) throws {
        try store.insert(HistoryRecord(rawTranscript: raw, finalText: final ?? raw, llmText: llm))
    }

    func testRunningFindsRun() throws {
        try add(raw: "I run every morning")
        XCTAssertEqual(try store.entries(matching: "running").count, 1)
        XCTAssertEqual(try store.count(matching: "running"), 1)
    }

    func testRunFindsRunningAndRuns() throws {
        try add(raw: "she was running fast")
        try add(raw: "he runs the team")
        XCTAssertEqual(try store.entries(matching: "run").count, 2)
    }

    func testSearchCoversRawLLMAndFinal() throws {
        try add(raw: "alpha words", final: "final bravo", llm: "model charlie")
        XCTAssertEqual(try store.entries(matching: "alpha").count, 1)
        XCTAssertEqual(try store.entries(matching: "bravo").count, 1)
        XCTAssertEqual(try store.entries(matching: "charlie").count, 1)
    }

    func testCaseAndDiacriticsInsensitive() throws {
        try add(raw: "Résumé review at the Café")
        XCTAssertEqual(try store.entries(matching: "resume").count, 1)
        XCTAssertEqual(try store.entries(matching: "CAFE").count, 1)
    }

    func testPrefixWhileTyping() throws {
        try add(raw: "kubernetes deployment")
        XCTAssertEqual(try store.entries(matching: "kube").count, 1)
        XCTAssertEqual(try store.entries(matching: "deployments kub").count, 1)
        XCTAssertEqual(try store.entries(matching: "deployments nothing").count, 0, "every term must match")
    }

    func testHostileInputNeverThrows() throws {
        try add(raw: "plain text")
        for query in ["\"", "AND", "OR NOT", "(", "*", "NEAR(a b)", "a:b", "-x", "^start"] {
            XCTAssertNoThrow(try store.entries(matching: query), query)
            XCTAssertNoThrow(try store.count(matching: query), query)
        }
    }

    func testHighlighterFindsStemmedWords() {
        let text = "We kept running and the runner ran on"
        let ranges = SearchHighlighter.ranges(in: text, query: "running")
        let words = ranges.map { String(text[$0]) }
        XCTAssertEqual(words, ["running", "runner"])

        let accents = SearchHighlighter.ranges(in: "Le Café est ouvert", query: "cafe")
        XCTAssertEqual(accents.count, 1)
        XCTAssertTrue(SearchHighlighter.ranges(in: "anything", query: "  ").isEmpty)
    }
}
