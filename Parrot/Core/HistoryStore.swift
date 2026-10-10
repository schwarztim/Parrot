import Foundation
import SQLite3

/// SQLite-backed store of dictation history with full-text search (FTS5).
///
/// Uses the system libsqlite3 (FTS5 is compiled in on macOS), so no dependency
/// is added. All access is serialized on a private queue; the database path is
/// injectable so tests run against a throwaway file.
///
/// Schema version 2 adds the recording folder, audio, timings, models, word
/// counts, the from-file flag, a unique `source_key`, the language model's
/// text, a Porter-stemmed search index over raw, LLM and final text, and a
/// stats ledger that outlives deleted recordings. Opening a version 1
/// database migrates it in one transaction and keeps every row.
final class HistoryStore: @unchecked Sendable {

    static let schemaVersion: Int32 = 2

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "com.parrot.history")

    /// Parent of the recording folders this store may delete. Folders
    /// anywhere else (imported recordings) are never removed.
    let recordingsRoot: URL

    // SQLite wants SQLITE_TRANSIENT so it copies bound strings.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parrot.db")
    }

    /// Opens (or creates) the database at the given URL and applies the schema.
    ///
    /// - Parameter recordingsRoot: Defaults to `recordings/` beside the
    ///   database, which is `AppPaths.recordings` for the app's database.
    init(databaseURL: URL, recordingsRoot: URL? = nil) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw HistoryError.openFailed
        }
        self.db = handle
        self.recordingsRoot = recordingsRoot
            ?? databaseURL.deletingLastPathComponent().appendingPathComponent("recordings", isDirectory: true)
        sqlite3_busy_timeout(db, 1000)
        do {
            try migrate()
        } catch {
            sqlite3_close(handle)
            throw error
        }

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

    private static let v1Table = """
        CREATE TABLE IF NOT EXISTS history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp REAL NOT NULL,
          raw_transcript TEXT NOT NULL,
          final_text TEXT NOT NULL,
          app_bundle_id TEXT,
          mode_name TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);
        """

    /// Columns added by version 2, with their definitions.
    private static let v2Columns: [(String, String)] = [
        ("llm_text", "TEXT"),
        ("app_name", "TEXT"),
        ("folder_path", "TEXT"),
        ("audio_path", "TEXT"),
        ("duration", "REAL NOT NULL DEFAULT 0"),
        ("processing_time", "REAL NOT NULL DEFAULT 0"),
        ("llm_processing_time", "REAL NOT NULL DEFAULT 0"),
        ("voice_model", "TEXT"),
        ("language_model", "TEXT"),
        ("language", "TEXT"),
        ("device", "TEXT"),
        ("raw_word_count", "INTEGER NOT NULL DEFAULT 0"),
        ("llm_word_count", "INTEGER NOT NULL DEFAULT 0"),
        ("from_file", "INTEGER NOT NULL DEFAULT 0"),
        ("source_key", "TEXT"),
    ]

    private static let ftsTable = """
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
          raw_transcript, llm_text, final_text,
          content='history', content_rowid='id', tokenize='porter unicode61'
        );
        """

    private static let insertIndexTrigger = """
        CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
          INSERT INTO history_fts(rowid, raw_transcript, llm_text, final_text)
          VALUES (new.id, new.raw_transcript, new.llm_text, new.final_text);
        END;
        """

    private static let otherIndexTriggers = """
        CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
          INSERT INTO history_fts(history_fts, rowid, raw_transcript, llm_text, final_text)
          VALUES ('delete', old.id, old.raw_transcript, old.llm_text, old.final_text);
        END;
        CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE ON history BEGIN
          INSERT INTO history_fts(history_fts, rowid, raw_transcript, llm_text, final_text)
          VALUES ('delete', old.id, old.raw_transcript, old.llm_text, old.final_text);
          INSERT INTO history_fts(rowid, raw_transcript, llm_text, final_text)
          VALUES (new.id, new.raw_transcript, new.llm_text, new.final_text);
        END;
        """

    /// The stats ledger: one row per recording, keyed by source key (or row
    /// id), written by insert and update triggers. No delete trigger, so
    /// lifetime stats survive deleting a recording.
    private static let ledger = """
        CREATE TABLE IF NOT EXISTS stats_ledger (
          ledger_key TEXT PRIMARY KEY,
          history_id INTEGER,
          timestamp REAL NOT NULL,
          from_file INTEGER NOT NULL DEFAULT 0,
          app_name TEXT,
          app_bundle_id TEXT,
          mode_name TEXT,
          word_count INTEGER NOT NULL DEFAULT 0,
          llm_word_count INTEGER NOT NULL DEFAULT 0,
          duration REAL NOT NULL DEFAULT 0,
          processing_time REAL NOT NULL DEFAULT 0,
          llm_processing_time REAL NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_stats_ledger_timestamp ON stats_ledger(timestamp);
        """

    private static let ledgerColumns = """
        ledger_key, history_id, timestamp, from_file, app_name, app_bundle_id, mode_name,
        word_count, llm_word_count, duration, processing_time, llm_processing_time, updated_at
        """

    private static func ledgerValues(_ row: String) -> String {
        """
        COALESCE(\(row).source_key, 'id:' || \(row).id), \(row).id, \(row).timestamp, \(row).from_file,
        \(row).app_name, \(row).app_bundle_id, \(row).mode_name,
        CASE WHEN \(row).llm_word_count > 0 THEN \(row).llm_word_count ELSE \(row).raw_word_count END,
        \(row).llm_word_count, \(row).duration, \(row).processing_time, \(row).llm_processing_time,
        (julianday('now') - 2440587.5) * 86400.0
        """
    }

    /// Delete then insert rather than INSERT OR REPLACE: inside a trigger,
    /// the firing statement's conflict policy overrides the trigger's own.
    private static var ledgerTriggers: String {
        let key = "COALESCE(new.source_key, 'id:' || new.id)"
        return """
        CREATE TRIGGER IF NOT EXISTS history_ledger_ai AFTER INSERT ON history BEGIN
          DELETE FROM stats_ledger WHERE ledger_key = \(key);
          INSERT INTO stats_ledger(\(ledgerColumns)) VALUES (\(ledgerValues("new")));
        END;
        CREATE TRIGGER IF NOT EXISTS history_ledger_au AFTER UPDATE ON history BEGIN
          DELETE FROM stats_ledger WHERE ledger_key = \(key);
          INSERT INTO stats_ledger(\(ledgerColumns)) VALUES (\(ledgerValues("new")));
        END;
        """
    }

    /// Brings the database to `schemaVersion`, then makes sure every trigger
    /// exists (an interrupted bulk import can leave the index trigger off;
    /// the index is rebuilt in that case).
    private func migrate() throws {
        let version = try userVersion()
        if version < 2 {
            try transaction { try migrateToV2() }
        }

        let hadIndexTrigger = try triggerExists("history_ai")
        try exec(Self.insertIndexTrigger + Self.otherIndexTriggers + Self.ledgerTriggers)
        if version >= 2 && !hadIndexTrigger {
            try exec("INSERT INTO history_fts(history_fts) VALUES('rebuild');")
        }
    }

    /// Version 0 (new file) or 1 to version 2. Runs inside a transaction.
    private func migrateToV2() throws {
        try exec(Self.v1Table)

        let existing = try columnNames("history")
        for (name, definition) in Self.v2Columns where !existing.contains(name) {
            try exec("ALTER TABLE history ADD COLUMN \(name) \(definition);")
        }
        try exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_history_source_key ON history(source_key);")

        // The old index has two columns and no stemming: rebuild it.
        try exec("""
            DROP TRIGGER IF EXISTS history_ai;
            DROP TRIGGER IF EXISTS history_ad;
            DROP TRIGGER IF EXISTS history_au;
            DROP TABLE IF EXISTS history_fts;
            """)

        // Word counts for rows saved before version 2.
        var counts: [(Int64, Int)] = []
        let select = try prepare("SELECT id, raw_transcript FROM history WHERE raw_word_count = 0")
        while sqlite3_step(select) == SQLITE_ROW {
            counts.append((sqlite3_column_int64(select, 0), WordCounter.count(columnText(select, 1))))
        }
        sqlite3_finalize(select)
        let update = try prepare("UPDATE history SET raw_word_count = ? WHERE id = ?")
        for (id, count) in counts where count > 0 {
            sqlite3_reset(update)
            sqlite3_bind_int64(update, 1, Int64(count))
            sqlite3_bind_int64(update, 2, id)
            guard sqlite3_step(update) == SQLITE_DONE else {
                sqlite3_finalize(update)
                throw HistoryError.stepFailed
            }
        }
        sqlite3_finalize(update)

        try exec(Self.ledger)
        try exec("INSERT OR REPLACE INTO stats_ledger(\(Self.ledgerColumns)) SELECT \(Self.ledgerValues("history")) FROM history;")

        try exec(Self.ftsTable)
        try exec("INSERT INTO history_fts(history_fts) VALUES('rebuild');")
        try exec("PRAGMA user_version = \(Self.schemaVersion);")
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
        try insert(HistoryRecord(
            timestamp: timestamp, rawTranscript: rawTranscript, finalText: finalText,
            appBundleID: appBundleID, modeName: modeName
        ))
    }

    /// Saves one row. A row whose `sourceKey` is already stored is updated in
    /// place instead (launch reconciliation and re-saves stay idempotent).
    @discardableResult
    func insert(_ record: HistoryRecord) throws -> HistoryEntry {
        try queue.sync {
            let upsert = record.sourceKey == nil ? "" : """
                ON CONFLICT(source_key) DO UPDATE SET
                  timestamp = excluded.timestamp, raw_transcript = excluded.raw_transcript,
                  final_text = excluded.final_text, app_bundle_id = excluded.app_bundle_id,
                  mode_name = excluded.mode_name, llm_text = excluded.llm_text,
                  app_name = excluded.app_name, folder_path = excluded.folder_path,
                  audio_path = excluded.audio_path, duration = excluded.duration,
                  processing_time = excluded.processing_time,
                  llm_processing_time = excluded.llm_processing_time,
                  voice_model = excluded.voice_model, language_model = excluded.language_model,
                  language = excluded.language, device = excluded.device,
                  raw_word_count = excluded.raw_word_count, llm_word_count = excluded.llm_word_count,
                  from_file = excluded.from_file
                """
            let stmt = try prepare(Self.insertSQL(verb: "INSERT") + upsert)
            defer { sqlite3_finalize(stmt) }
            bind(record, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }

            var id = sqlite3_last_insert_rowid(db)
            if let key = record.sourceKey {
                let lookup = try prepare("SELECT id FROM history WHERE source_key = ?")
                defer { sqlite3_finalize(lookup) }
                bindText(lookup, 1, key)
                if sqlite3_step(lookup) == SQLITE_ROW { id = sqlite3_column_int64(lookup, 0) }
            }
            return Self.entry(id: id, record: record)
        }
    }

    /// Inserts many rows, skipping any whose source key is already stored.
    /// Each batch is one transaction. The search index trigger is off during
    /// the run and the index is rebuilt once at the end. Returns how many
    /// rows were added.
    @discardableResult
    func importRecords(
        _ records: [HistoryRecord],
        batchSize: Int = 500,
        progress: ((Int) -> Void)? = nil
    ) throws -> Int {
        guard !records.isEmpty else { return 0 }
        try queue.sync { try exec("DROP TRIGGER IF EXISTS history_ai;") }
        defer {
            queue.sync {
                try? exec(Self.insertIndexTrigger)
                try? exec("INSERT INTO history_fts(history_fts) VALUES('rebuild');")
            }
        }

        var inserted = 0
        var done = 0
        for start in stride(from: 0, to: records.count, by: max(1, batchSize)) {
            let batch = records[start..<min(start + max(1, batchSize), records.count)]
            inserted += try queue.sync {
                try transaction {
                    let stmt = try prepare(Self.insertSQL(verb: "INSERT OR IGNORE"))
                    defer { sqlite3_finalize(stmt) }
                    var added = 0
                    for record in batch {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        bind(record, to: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }
                        added += Int(sqlite3_changes(db))
                    }
                    return added
                }
            }
            done += batch.count
            progress?(done)
        }
        return inserted
    }

    private static let insertColumns = """
        timestamp, raw_transcript, final_text, app_bundle_id, mode_name, llm_text, app_name,
        folder_path, audio_path, duration, processing_time, llm_processing_time, voice_model,
        language_model, language, device, raw_word_count, llm_word_count, from_file, source_key
        """

    private static func insertSQL(verb: String) -> String {
        "\(verb) INTO history (\(insertColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
    }

    private func bind(_ r: HistoryRecord, to stmt: OpaquePointer?) {
        sqlite3_bind_double(stmt, 1, r.timestamp.timeIntervalSince1970)
        bindText(stmt, 2, r.rawTranscript)
        bindText(stmt, 3, r.finalText)
        bindTextOrNull(stmt, 4, r.appBundleID)
        bindTextOrNull(stmt, 5, r.modeName)
        bindTextOrNull(stmt, 6, r.llmText)
        bindTextOrNull(stmt, 7, r.appName)
        bindTextOrNull(stmt, 8, r.folderPath)
        bindTextOrNull(stmt, 9, r.audioPath)
        sqlite3_bind_double(stmt, 10, r.duration)
        sqlite3_bind_double(stmt, 11, r.processingTime)
        sqlite3_bind_double(stmt, 12, r.llmProcessingTime)
        bindTextOrNull(stmt, 13, r.voiceModel)
        bindTextOrNull(stmt, 14, r.languageModel)
        bindTextOrNull(stmt, 15, r.language)
        bindTextOrNull(stmt, 16, r.device)
        sqlite3_bind_int64(stmt, 17, Int64(r.rawWordCount ?? WordCounter.count(r.rawTranscript)))
        sqlite3_bind_int64(stmt, 18, Int64(r.llmWordCount ?? WordCounter.count(r.llmText)))
        sqlite3_bind_int(stmt, 19, r.fromFile ? 1 : 0)
        bindTextOrNull(stmt, 20, r.sourceKey)
    }

    private static func entry(id: Int64, record r: HistoryRecord) -> HistoryEntry {
        HistoryEntry(
            id: id, timestamp: r.timestamp, rawTranscript: r.rawTranscript, finalText: r.finalText,
            appBundleID: r.appBundleID, modeName: r.modeName, llmText: r.llmText, appName: r.appName,
            folderPath: r.folderPath, audioPath: r.audioPath, duration: r.duration,
            processingTime: r.processingTime, llmProcessingTime: r.llmProcessingTime,
            voiceModel: r.voiceModel, languageModel: r.languageModel, language: r.language,
            device: r.device, rawWordCount: r.rawWordCount ?? WordCounter.count(r.rawTranscript),
            llmWordCount: r.llmWordCount ?? WordCounter.count(r.llmText), fromFile: r.fromFile,
            sourceKey: r.sourceKey
        )
    }

    // MARK: - Query

    private static let selectColumns = [
        "id", "timestamp", "raw_transcript", "final_text", "app_bundle_id", "mode_name",
        "llm_text", "app_name", "folder_path", "audio_path", "duration", "processing_time",
        "llm_processing_time", "voice_model", "language_model", "language", "device",
        "raw_word_count", "llm_word_count", "from_file", "source_key",
    ]
    private static let selectList = selectColumns.joined(separator: ", ")
    private static let joinedSelectList = selectColumns.map { "h." + $0 }.joined(separator: ", ")

    private func readEntry(_ stmt: OpaquePointer?) -> HistoryEntry {
        HistoryEntry(
            id: sqlite3_column_int64(stmt, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            rawTranscript: columnText(stmt, 2) ?? "",
            finalText: columnText(stmt, 3) ?? "",
            appBundleID: columnText(stmt, 4),
            modeName: columnText(stmt, 5),
            llmText: columnText(stmt, 6),
            appName: columnText(stmt, 7),
            folderPath: columnText(stmt, 8),
            audioPath: columnText(stmt, 9),
            duration: sqlite3_column_double(stmt, 10),
            processingTime: sqlite3_column_double(stmt, 11),
            llmProcessingTime: sqlite3_column_double(stmt, 12),
            voiceModel: columnText(stmt, 13),
            languageModel: columnText(stmt, 14),
            language: columnText(stmt, 15),
            device: columnText(stmt, 16),
            rawWordCount: Int(sqlite3_column_int64(stmt, 17)),
            llmWordCount: Int(sqlite3_column_int64(stmt, 18)),
            fromFile: sqlite3_column_int(stmt, 19) != 0,
            sourceKey: columnText(stmt, 20)
        )
    }

    /// One page of entries, newest first. A non-empty `query` is a full-text
    /// search over raw, LLM and final text (Porter stemming, so "running"
    /// finds "run").
    func entries(matching query: String? = nil, limit: Int = 200, offset: Int = 0) throws -> [HistoryEntry] {
        try queue.sync {
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stmt: OpaquePointer?
            if trimmed.isEmpty {
                stmt = try prepare("SELECT \(Self.selectList) FROM history ORDER BY timestamp DESC, id DESC LIMIT ? OFFSET ?")
                sqlite3_bind_int(stmt, 1, Int32(limit))
                sqlite3_bind_int(stmt, 2, Int32(offset))
            } else {
                stmt = try prepare("""
                    SELECT \(Self.joinedSelectList)
                    FROM history h JOIN history_fts f ON h.id = f.rowid
                    WHERE history_fts MATCH ? ORDER BY h.timestamp DESC, h.id DESC LIMIT ? OFFSET ?
                    """)
                bindText(stmt, 1, Self.ftsQuery(from: trimmed))
                sqlite3_bind_int(stmt, 2, Int32(limit))
                sqlite3_bind_int(stmt, 3, Int32(offset))
            }
            defer { sqlite3_finalize(stmt) }

            var results: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readEntry(stmt))
            }
            return results
        }
    }

    func entry(id: Int64) throws -> HistoryEntry? {
        try queue.sync {
            let stmt = try prepare("SELECT \(Self.selectList) FROM history WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            return sqlite3_step(stmt) == SQLITE_ROW ? readEntry(stmt) : nil
        }
    }

    /// Converts free user text into a safe FTS5 MATCH expression. Each token
    /// is quoted (embedded quotes doubled) and matched as a whole word or a
    /// prefix; tokens are joined with AND. Neutralizes FTS operators that
    /// would otherwise throw.
    static func ftsQuery(from userText: String) -> String {
        let tokens = userText.split(whereSeparator: { $0.isWhitespace })
        let groups = tokens.map { token -> String in
            let escaped = "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return "(\(escaped) OR \(escaped)*)"
        }
        return groups.joined(separator: " AND ")
    }

    func count() throws -> Int {
        try count(matching: nil)
    }

    /// Total rows, or rows matching a search (for "select all").
    func count(matching query: String?) throws -> Int {
        try queue.sync {
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stmt: OpaquePointer?
            if trimmed.isEmpty {
                stmt = try prepare("SELECT COUNT(*) FROM history")
            } else {
                stmt = try prepare("SELECT COUNT(*) FROM history_fts WHERE history_fts MATCH ?")
                bindText(stmt, 1, Self.ftsQuery(from: trimmed))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Rows older than `days` days (what a retention change would delete).
    func countOlderThan(days: Int, now: Date = Date()) throws -> Int {
        guard days > 0 else { return 0 }
        return try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM history WHERE timestamp < ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970 - Double(days) * 86_400)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Every stored source key starting with `prefix`.
    func sourceKeys(withPrefix prefix: String) throws -> Set<String> {
        try queue.sync {
            let stmt = try prepare("SELECT source_key FROM history WHERE substr(source_key, 1, ?) = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(prefix.count))
            bindText(stmt, 2, prefix)
            var keys = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let key = columnText(stmt, 0) { keys.insert(key) }
            }
            return keys
        }
    }

    /// Row ids and folders of rows with a source key starting with `prefix`.
    func folderRows(sourceKeyPrefix prefix: String) throws -> [(id: Int64, folderPath: String?)] {
        try queue.sync {
            let stmt = try prepare("SELECT id, folder_path FROM history WHERE substr(source_key, 1, ?) = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(prefix.count))
            bindText(stmt, 2, prefix)
            var rows: [(Int64, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), columnText(stmt, 1)))
            }
            return rows
        }
    }

    // MARK: - Stats Ledger

    /// One ledger row: what stats read.
    struct LedgerRow: Equatable {
        var timestamp: Date
        var fromFile: Bool
        var appName: String?
        var appBundleID: String?
        var modeName: String?
        var wordCount: Int
        var duration: TimeInterval
    }

    /// Ledger rows since `since` (all when nil). Deleted recordings stay in.
    func ledgerRows(since: Date? = nil) throws -> [LedgerRow] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT timestamp, from_file, app_name, app_bundle_id, mode_name, word_count, duration
                FROM stats_ledger WHERE timestamp >= ? ORDER BY timestamp
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
            var rows: [LedgerRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(LedgerRow(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    fromFile: sqlite3_column_int(stmt, 1) != 0,
                    appName: columnText(stmt, 2),
                    appBundleID: columnText(stmt, 3),
                    modeName: columnText(stmt, 4),
                    wordCount: Int(sqlite3_column_int64(stmt, 5)),
                    duration: sqlite3_column_double(stmt, 6)
                ))
            }
            return rows
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

    /// Deletes one recording: its row, and its folder when Parrot owns it.
    func delete(id: Int64) throws {
        _ = try delete(ids: [id])
    }

    /// Deletes recordings by id, folders included where Parrot owns them.
    /// Returns how many rows were removed.
    @discardableResult
    func delete(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var removed = 0
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let targets = try selectTargets("WHERE id IN (\(placeholders))") { stmt in
                for (index, id) in chunk.enumerated() { sqlite3_bind_int64(stmt, Int32(index + 1), id) }
            }
            removed += try deleteTargets(targets)
        }
        return removed
    }

    /// Deletes every recording matching a search (select all), even rows
    /// not yet paged in. An empty query deletes everything.
    @discardableResult
    func delete(matching query: String?) throws -> Int {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return try deleteTargets(selectTargets("") { _ in })
        }
        let targets = try selectTargets("WHERE id IN (SELECT rowid FROM history_fts WHERE history_fts MATCH ?)") { stmt in
            self.bindText(stmt, 1, Self.ftsQuery(from: trimmed))
        }
        return try deleteTargets(targets)
    }

    func deleteAll() throws {
        try delete(matching: nil)
    }

    /// Deletes rows older than `days` days, and their folders where Parrot
    /// owns them. Returns the number deleted.
    @discardableResult
    func pruneOlderThan(days: Int, now: Date = Date()) throws -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        let targets = try selectTargets("WHERE timestamp < ?") { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
        }
        return try deleteTargets(targets)
    }

    private func selectTargets(_ whereClause: String, bind: (OpaquePointer?) -> Void) throws -> [(Int64, String?)] {
        try queue.sync {
            let stmt = try prepare("SELECT id, folder_path FROM history \(whereClause)")
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            var rows: [(Int64, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), columnText(stmt, 1)))
            }
            return rows
        }
    }

    /// Removes rows in chunks of 500 (one transaction each, retried one by
    /// one when a chunk fails), then the folders Parrot owns.
    private func deleteTargets(_ targets: [(Int64, String?)]) throws -> Int {
        var removed = 0
        for start in stride(from: 0, to: targets.count, by: 500) {
            let chunk = Array(targets[start..<min(start + 500, targets.count)])
            let ids = chunk.map(\.0)
            do {
                removed += try queue.sync { try transaction { try deleteRows(ids) } }
            } catch {
                diagLog("[Parrot:History] Chunk delete failed, retrying one by one: \(error)")
                for id in ids {
                    removed += (try? queue.sync { try deleteRows([id]) }) ?? 0
                }
            }
            for case let (_, path?) in chunk {
                RecordingFolders.removeIfOwned(URL(fileURLWithPath: path, isDirectory: true), root: recordingsRoot)
            }
        }
        return removed
    }

    private func deleteRows(_ ids: [Int64]) throws -> Int {
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let stmt = try prepare("DELETE FROM history WHERE id IN (\(placeholders))")
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(index + 1), id) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.stepFailed }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Statement Helpers

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            diagLog("[Parrot:History] SQL failed: \(message)")
            throw HistoryError.schemaFailed
        }
    }

    /// Runs `body` in one transaction; rolls back on a throw. Call on the queue.
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    private func columnNames(_ table: String) throws -> Set<String> {
        let stmt = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 1) { names.insert(name) }
        }
        return names
    }

    private func triggerExists(_ name: String) throws -> Bool {
        let stmt = try prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

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
