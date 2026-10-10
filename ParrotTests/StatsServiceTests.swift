import XCTest

@testable import Parrot

/// Usage stats from the ledger: words per minute, total words, apps used,
/// time saved against the typing speed, file transcriptions excluded.
@MainActor
final class StatsServiceTests: XCTestCase {

    private func row(words: Int, seconds: Double, app: String? = "com.app.a", mode: String? = "Default",
                     fromFile: Bool = false, at time: Double = 1_700_000_000) -> HistoryStore.LedgerRow {
        HistoryStore.LedgerRow(
            timestamp: Date(timeIntervalSince1970: time), fromFile: fromFile, appName: nil,
            appBundleID: app, modeName: mode, wordCount: words, duration: seconds
        )
    }

    func testTotalsWPMAndTimeSaved() {
        let rows = [
            row(words: 150, seconds: 60),                     // 150 wpm, typing 40 wpm = 225 s, saves 165 s
            row(words: 50, seconds: 30, app: "com.app.b"),    // typing 75 s, saves 45 s
            row(words: 10, seconds: 60, app: "com.app.b"),    // typing 15 s, saves 0 (never negative)
            row(words: 0, seconds: 5, mode: "Email"),         // no words: out of WPM and time saved
            row(words: 999, seconds: 100, fromFile: true),    // file transcription: excluded
        ]
        let snapshot = StatsCalculator.snapshot(rows: rows, typingWPM: 40)

        XCTAssertEqual(snapshot.dictationCount, 4)
        XCTAssertEqual(snapshot.wordCount, 210)
        XCTAssertEqual(snapshot.duration, 155, accuracy: 0.001)
        XCTAssertEqual(snapshot.wordsPerMinute, 210.0 / (150.0 / 60), accuracy: 0.001)
        XCTAssertEqual(snapshot.timeSaved, 210, accuracy: 0.001)
        XCTAssertEqual(snapshot.appsUsed, 2)
        XCTAssertEqual(snapshot.mostUsedMode, "Default")
    }

    func testEmptyIsZero() {
        XCTAssertEqual(StatsCalculator.snapshot(rows: [], typingWPM: 40), .zero)
    }

    func testServiceReadsLedgerSinceDateAndSurvivesDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-stats-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(databaseURL: url)
        let old = try store.insert(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_600_000_000), rawTranscript: "one two three four",
            finalText: "x", duration: 2, sourceKey: "parrot:1600000000"))
        try store.insert(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), rawTranscript: "raw only here",
            finalText: "x", llmText: "model said five words here", duration: 3, sourceKey: "parrot:1700000000"))
        try store.insert(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_100), rawTranscript: "file words",
            finalText: "x", duration: 3, fromFile: true, sourceKey: "parrot:1700000100"))

        let service = HistoryStatsService(history: store)
        service.typingWPM = { 60 }

        XCTAssertEqual(service.snapshot(since: nil).wordCount, 9, "LLM count wins when non-zero; files excluded")
        XCTAssertEqual(service.snapshot(since: Date(timeIntervalSince1970: 1_650_000_000)).wordCount, 5)

        try store.delete(id: old.id)
        XCTAssertEqual(service.snapshot(since: nil).dictationCount, 2, "ledger keeps deleted recordings")
    }

    func testTypingSpeedSettingDefaultsToForty() {
        let suite = "parrot-stats-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(settings.general.effectiveTypingWPM, 40)
        settings.general.typingWPM = 75
        XCTAssertEqual(settings.general.effectiveTypingWPM, 75)
        XCTAssertEqual(defaults.double(forKey: "parrot.general.typingWPM"), 75, "one key, written by General")
        settings.general.typingWPM = 0
        XCTAssertEqual(settings.general.effectiveTypingWPM, 40, "a non-positive speed reads as the default")
        XCTAssertFalse(settings.history.savePromptContext, "prompt and context are off by default")
    }
}
