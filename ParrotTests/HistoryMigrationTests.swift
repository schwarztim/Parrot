import SQLite3
import XCTest

@testable import Parrot

/// A version 1 history database (built here with the old schema) opened by
/// today's HistoryStore keeps every row and gains the version 2 columns,
/// the stemmed index over raw, LLM and final text, and the stats ledger.
final class HistoryMigrationTests: XCTestCase {

    private var dbURL: URL!

    /// The schema HistoryStore created before version 2.
    private let v1Schema = """
        PRAGMA user_version = 1;
        CREATE TABLE IF NOT EXISTS history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp REAL NOT NULL,
          raw_transcript TEXT NOT NULL,
          final_text TEXT NOT NULL,
          app_bundle_id TEXT,
          mode_name TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
          raw_transcript, final_text, content='history', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
          INSERT INTO history_fts(rowid, raw_transcript, final_text)
          VALUES (new.id, new.raw_transcript, new.final_text);
        END;
        CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
          INSERT INTO history_fts(history_fts, rowid, raw_transcript, final_text)
          VALUES ('delete', old.id, old.raw_transcript, old.final_text);
        END;
        CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE ON history BEGIN
          INSERT INTO history_fts(history_fts, rowid, raw_transcript, final_text)
          VALUES ('delete', old.id, old.raw_transcript, old.final_text);
          INSERT INTO history_fts(rowid, raw_transcript, final_text)
          VALUES (new.id, new.raw_transcript, new.final_text);
        END;
        INSERT INTO history (timestamp, raw_transcript, final_text, app_bundle_id, mode_name)
          VALUES (1700000000, 'we were running late', 'We were running late.', 'com.apple.mail', 'Email');
        INSERT INTO history (timestamp, raw_transcript, final_text, app_bundle_id, mode_name)
          VALUES (1700000100, 'ship the build today', 'Ship the build today.', NULL, NULL);
        INSERT INTO history (timestamp, raw_transcript, final_text, app_bundle_id, mode_name)
          VALUES (1700000200, 'café meeting notes', 'Café meeting notes.', 'com.apple.Notes', 'Note');
        DELETE FROM history WHERE id = 2;
        INSERT INTO history (timestamp, raw_transcript, final_text, app_bundle_id, mode_name)
          VALUES (1700000300, 'fourth one here', 'Fourth one here.', NULL, 'Default');
        """

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-migrate-\(UUID().uuidString).db")
        try exec(v1Schema)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) } ?? ""
        sqlite3_free(err)
        XCTAssertEqual(rc, SQLITE_OK, message)
    }

    private func scalar(_ sql: String) -> Int {
        var db: OpaquePointer?
        sqlite3_open(dbURL.path, &db)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }

    func testVersionOneRowsSurvive() throws {
        let store = try HistoryStore(databaseURL: dbURL)
        let entries = try store.entries()

        XCTAssertEqual(entries.map(\.id), [4, 3, 1], "ids and order kept")
        XCTAssertEqual(entries.map(\.finalText), ["Fourth one here.", "Café meeting notes.", "We were running late."])
        XCTAssertEqual(entries.last?.appBundleID, "com.apple.mail")
        XCTAssertEqual(entries.last?.modeName, "Email")
        XCTAssertEqual(entries.last?.rawWordCount, 4, "word counts backfilled")
        XCTAssertNil(entries.last?.sourceKey)
        XCTAssertNil(entries.last?.folderPath)
        XCTAssertEqual(scalar("PRAGMA user_version"), 2)
    }

    func testMigratedIndexStemsAndCoversNewRows() throws {
        let store = try HistoryStore(databaseURL: dbURL)

        XCTAssertEqual(try store.entries(matching: "run").map(\.id), [1], "old rows reindexed with stemming")
        XCTAssertEqual(try store.entries(matching: "cafe").map(\.id), [3], "diacritics folded")
        XCTAssertEqual(try store.entries(matching: "build").count, 0, "a row deleted before migration stays gone")

        try store.insert(HistoryRecord(rawTranscript: "raw words", finalText: "final words", llmText: "the model replied"))
        XCTAssertEqual(try store.entries(matching: "replied").count, 1, "LLM text is searchable")
    }

    func testLedgerBackfilledAndSurvivesDelete() throws {
        let store = try HistoryStore(databaseURL: dbURL)
        XCTAssertEqual(try store.ledgerRows().count, 3)

        try store.delete(id: 1)
        XCTAssertEqual(try store.count(), 2)
        XCTAssertEqual(try store.ledgerRows().count, 3, "stats outlive deleted recordings")
    }

    func testReopeningIsIdempotent() throws {
        _ = try HistoryStore(databaseURL: dbURL)
        let reopened = try HistoryStore(databaseURL: dbURL)
        XCTAssertEqual(try reopened.count(), 3)
        XCTAssertEqual(try reopened.entries(matching: "notes").count, 1)
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM history_fts"), 3)
    }

    func testSourceKeyIsUnique() throws {
        let store = try HistoryStore(databaseURL: dbURL)
        let first = try store.insert(HistoryRecord(rawTranscript: "a", finalText: "first", sourceKey: "parrot:1"))
        let second = try store.insert(HistoryRecord(rawTranscript: "a", finalText: "second", sourceKey: "parrot:1"))

        XCTAssertEqual(first.id, second.id, "the same source key updates in place")
        XCTAssertEqual(try store.count(), 4)
        XCTAssertEqual(try store.entry(id: first.id)?.finalText, "second")
        XCTAssertEqual(try store.entries(matching: "first").count, 0, "index follows the update")
    }

    func testFreshDatabaseIsVersionTwo() throws {
        try? FileManager.default.removeItem(at: dbURL)
        let store = try HistoryStore(databaseURL: dbURL)
        XCTAssertEqual(try store.count(), 0)
        XCTAssertEqual(scalar("PRAGMA user_version"), 2)
        try store.insert(rawTranscript: "hello", finalText: "Hello", appBundleID: nil, modeName: nil)
        XCTAssertEqual(try store.entries(matching: "hello").count, 1)
    }
}
