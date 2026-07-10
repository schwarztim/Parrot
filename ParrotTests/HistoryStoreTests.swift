import XCTest

@testable import Parrot

/// Exercises HistoryStore against a throwaway temp database (path injected), so
/// the real parrot.db is never touched.
final class HistoryStoreTests: XCTestCase {

    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-hist-\(UUID().uuidString).db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    private func store() throws -> HistoryStore { try HistoryStore(databaseURL: dbURL) }

    func testInsertAssignsIDAndFetchNewestFirst() throws {
        let s = try store()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try s.insert(rawTranscript: "one", finalText: "One", appBundleID: nil, modeName: nil, timestamp: base)
        try s.insert(rawTranscript: "two", finalText: "Two", appBundleID: nil, modeName: nil, timestamp: base.addingTimeInterval(10))
        try s.insert(rawTranscript: "three", finalText: "Three", appBundleID: nil, modeName: nil, timestamp: base.addingTimeInterval(20))
        let entries = try s.entries()
        XCTAssertEqual(entries.map(\.finalText), ["Three", "Two", "One"])
        XCTAssertTrue(entries.allSatisfy { $0.id > 0 })
    }

    func testSearchMatchesRawAndFinalText() throws {
        let s = try store()
        try s.insert(rawTranscript: "git hub", finalText: "GitHub", appBundleID: nil, modeName: nil)
        try s.insert(rawTranscript: "unrelated", finalText: "Nothing", appBundleID: nil, modeName: nil)
        XCTAssertEqual(try s.entries(matching: "github").count, 1)
        XCTAssertEqual(try s.entries(matching: "hub").count, 1)
        XCTAssertEqual(try s.entries(matching: "nothing").count, 1)
    }

    func testSearchPrefixAndCaseInsensitive() throws {
        let s = try store()
        try s.insert(rawTranscript: "deploy to kubernetes", finalText: "Deploy to Kubernetes", appBundleID: nil, modeName: nil)
        XCTAssertEqual(try s.entries(matching: "Kuber").count, 1)
        XCTAssertEqual(try s.entries(matching: "KUBERNETES").count, 1)
    }

    func testFTSQuerySanitization() throws {
        let s = try store()
        try s.insert(rawTranscript: "safe text", finalText: "Safe", appBundleID: nil, modeName: nil)
        // Hostile FTS operators must not throw.
        XCTAssertNoThrow(try s.entries(matching: "\"AND (NEAR"))
        XCTAssertNoThrow(try s.entries(matching: "* OR *"))
    }

    func testUpdateFinalTextPersistsAndReindexes() throws {
        let s = try store()
        let e = try s.insert(rawTranscript: "raw", finalText: "oldword", appBundleID: nil, modeName: nil)
        try s.updateFinalText(id: e.id, newText: "newword")
        XCTAssertEqual(try s.entries(matching: "newword").count, 1)
        XCTAssertEqual(try s.entries(matching: "oldword").count, 0)
    }

    func testDeleteItemAndDeleteAll() throws {
        let s = try store()
        let a = try s.insert(rawTranscript: "a", finalText: "A", appBundleID: nil, modeName: nil)
        _ = try s.insert(rawTranscript: "b", finalText: "B", appBundleID: nil, modeName: nil)
        XCTAssertEqual(try s.count(), 2)
        try s.delete(id: a.id)
        XCTAssertEqual(try s.count(), 1)
        try s.deleteAll()
        XCTAssertEqual(try s.count(), 0)
        XCTAssertEqual(try s.entries(matching: "b").count, 0)
    }

    func testRetentionPrune() throws {
        let s = try store()
        let now = Date()
        try s.insert(rawTranscript: "recent", finalText: "recent", appBundleID: nil, modeName: nil, timestamp: now)
        try s.insert(rawTranscript: "tenago", finalText: "tenago", appBundleID: nil, modeName: nil, timestamp: now.addingTimeInterval(-10 * 86_400))
        try s.insert(rawTranscript: "fortyago", finalText: "fortyago", appBundleID: nil, modeName: nil, timestamp: now.addingTimeInterval(-40 * 86_400))
        let deleted = try s.pruneOlderThan(days: 30)
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try s.count(), 2)
    }

    func testReopenPersists() throws {
        do {
            let s = try store()
            try s.insert(rawTranscript: "persist", finalText: "Persist", appBundleID: "com.x", modeName: "M")
        }
        let reopened = try store()
        let entries = try reopened.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.appBundleID, "com.x")
        XCTAssertEqual(entries.first?.modeName, "M")
    }

    func testNilBundleIDAndModeRoundTrip() throws {
        let s = try store()
        try s.insert(rawTranscript: "r", finalText: "F", appBundleID: nil, modeName: nil)
        let e = try XCTUnwrap(try s.entries().first)
        XCTAssertNil(e.appBundleID)
        XCTAssertNil(e.modeName)
    }

    func testBackupExclusion() throws {
        _ = try store()
        let values = try dbURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
