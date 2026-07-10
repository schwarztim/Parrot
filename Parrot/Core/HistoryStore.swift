import Foundation
import SQLite3

/// SQLite-backed store of dictation history with full-text search (FTS5).
///
/// Uses the system libsqlite3 (FTS5 is compiled in on macOS), so no dependency
/// is added. All access is serialized on a private queue; the database path is
/// injectable so tests run against a throwaway file.
final class HistoryStore {

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "com.parrot.history")

    // SQLite wants SQLITE_TRANSIENT so it copies bound strings.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parrot.db")
    }

    /// Opens (or creates) the database at the given URL and applies the schema.
    init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw HistoryError.openFailed
        }
        self.db = handle
        sqlite3_busy_timeout(db, 1000)
        try createSchema()

        // Keep the history out of iCloud/Time Machine backups.
        var url = databaseURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        let sql = """
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
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            sqlite3_free(errMsg)
            throw HistoryError.schemaFailed
        }
    }

    // MARK: - Insert

    @discardableResult
    func insert(
        rawTranscript: String,
        finalText: String,
        appBundleID: String?,
        modeName: String?,
        timestamp: Date = Date()
    ) throws -> HistoryEntry {
        try queue.sync {
            let sql = """
                INSERT INTO history (timestamp, raw_transcript, final_text, app_bundle_id, mode_name)
                VALUES (?, ?, ?, ?, ?)
                """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
            bindText(stmt, 2, rawTranscript)
            bindText(stmt, 3, finalText)
            bindTextOrNull(stmt, 4, appBundleID)
            bindTextOrNull(stmt, 5, modeName)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }
            let id = sqlite3_last_insert_rowid(db)
            return HistoryEntry(
                id: id, timestamp: timestamp, rawTranscript: rawTranscript,
                finalText: finalText, appBundleID: appBundleID, modeName: modeName
            )
        }
    }

    // MARK: - Query

    func entries(matching query: String? = nil, limit: Int = 200, offset: Int = 0) throws -> [HistoryEntry] {
        try queue.sync {
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stmt: OpaquePointer?
            if trimmed.isEmpty {
                stmt = try prepare("SELECT id, timestamp, raw_transcript, final_text, app_bundle_id, mode_name FROM history ORDER BY timestamp DESC LIMIT ? OFFSET ?")
                sqlite3_bind_int(stmt, 1, Int32(limit))
                sqlite3_bind_int(stmt, 2, Int32(offset))
            } else {
                stmt = try prepare("""
                    SELECT h.id, h.timestamp, h.raw_transcript, h.final_text, h.app_bundle_id, h.mode_name
                    FROM history h JOIN history_fts f ON h.id = f.rowid
                    WHERE history_fts MATCH ? ORDER BY h.timestamp DESC LIMIT ? OFFSET ?
                    """)
                bindText(stmt, 1, Self.ftsQuery(from: trimmed))
                sqlite3_bind_int(stmt, 2, Int32(limit))
                sqlite3_bind_int(stmt, 3, Int32(offset))
            }
            defer { sqlite3_finalize(stmt) }

            var results: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(HistoryEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    rawTranscript: columnText(stmt, 2) ?? "",
                    finalText: columnText(stmt, 3) ?? "",
                    appBundleID: columnText(stmt, 4),
                    modeName: columnText(stmt, 5)
                ))
            }
            return results
        }
    }

    /// Converts free user text into a safe FTS5 MATCH expression: each token is
    /// quoted (embedded quotes doubled) and made a prefix match, joined by
    /// implicit AND. Neutralizes FTS operators that would otherwise throw.
    static func ftsQuery(from userText: String) -> String {
        let tokens = userText.split(whereSeparator: { $0.isWhitespace })
        let quoted = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }
        return quoted.joined(separator: " ")
    }

    func count() throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM history")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Mutate

    func updateFinalText(id: Int64, newText: String) throws {
        try queue.sync {
            let stmt = try prepare("UPDATE history SET final_text = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, newText)
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }
        }
    }

    func delete(id: Int64) throws {
        try queue.sync {
            let stmt = try prepare("DELETE FROM history WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }
        }
    }

    func deleteAll() throws {
        try queue.sync {
            var errMsg: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, "DELETE FROM history", nil, nil, &errMsg) == SQLITE_OK else {
                sqlite3_free(errMsg)
                throw HistoryError.stepFailed
            }
        }
    }

    /// Deletes rows older than `days` days. Returns the number deleted.
    @discardableResult
    func pruneOlderThan(days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        return try queue.sync {
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
            let stmt = try prepare("DELETE FROM history WHERE timestamp < ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Statement Helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}

// MARK: - Errors

enum HistoryError: LocalizedError {
    case openFailed
    case schemaFailed
    case prepareFailed(String)
    case stepFailed

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Could not open the history database."
        case .schemaFailed: return "Could not initialize the history database."
        case .prepareFailed(let msg): return "History query failed: \(msg)"
        case .stepFailed: return "History write failed."
        }
    }
}
