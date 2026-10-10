import XCTest

@testable import Parrot

/// Retention options, the delete-count confirmation, and cleanup that
/// removes Parrot's own folders but never an imported one.
@MainActor
final class RetentionTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var history: HistoryStore!

    private var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        suiteName = "parrot-retention-\(UUID().uuidString)"
        history = try HistoryStore(databaseURL: root.appendingPathComponent("parrot.db"))
    }

    override func tearDown() async throws {
        history = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!), secrets: InMemorySecretStore())
    }

    @discardableResult
    private func addRecording(daysAgo: Double, now: Date, imported: Bool = false) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970 - daysAgo * 86_400)
        let folder: URL
        if imported {
            folder = root.appendingPathComponent("superwhisper/recordings/\(stamp)", isDirectory: true)
        } else {
            folder = recordings.appendingPathComponent(String(stamp), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("output.wav"))
        try history.insert(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: TimeInterval(stamp)),
            rawTranscript: "r\(stamp)", finalText: "f\(stamp)",
            folderPath: folder.path,
            sourceKey: imported ? "superwhisper:\(stamp)" : "parrot:\(stamp)"
        ))
        return folder
    }

    func testOptionsMatchTheSpec() {
        XCTAssertEqual(RetentionOption.allCases.map(\.label),
                       ["Forever", "1 day", "1 week", "2 weeks", "1 month", "6 months", "1 year"])
        XCTAssertEqual(RetentionOption.allCases.map(\.days), [0, 1, 7, 14, 30, 180, 365])
        XCTAssertEqual(makeSettings().history.historyRetentionDays, 30, "existing default kept: 1 month")
    }

    func testLegacyValueStaysSelectable() {
        XCTAssertEqual(RetentionOption.choices(including: 90), [0, 1, 7, 14, 30, 90, 180, 365])
        XCTAssertEqual(RetentionOption.choices(including: 30), [0, 1, 7, 14, 30, 180, 365])
        XCTAssertEqual(RetentionOption.label(forDays: 90), "90 days")
        XCTAssertEqual(RetentionOption.label(forDays: 0), "Forever")
    }

    func testConfirmationOnlyWhenShortening() {
        XCTAssertTrue(RetentionOption.needsConfirmation(from: 0, to: 365))
        XCTAssertTrue(RetentionOption.needsConfirmation(from: 30, to: 7))
        XCTAssertFalse(RetentionOption.needsConfirmation(from: 7, to: 30))
        XCTAssertFalse(RetentionOption.needsConfirmation(from: 30, to: 0))
        XCTAssertEqual(RetentionOption.confirmationMessage(count: 3),
                       "This will delete 3 recordings and their audio. This action cannot be undone.")
    }

    func testCountAndPruneDeleteOwnedFoldersOnly() throws {
        let now = Date()
        let recent = try addRecording(daysAgo: 2, now: now)
        let old = try addRecording(daysAgo: 10, now: now)
        let older = try addRecording(daysAgo: 40, now: now)
        let importedOld = try addRecording(daysAgo: 60, now: now, imported: true)

        XCTAssertEqual(try history.countOlderThan(days: 7, now: now), 3)
        XCTAssertEqual(try history.countOlderThan(days: 0, now: now), 0, "forever deletes nothing")

        let deleted = try history.pruneOlderThan(days: 7, now: now)
        XCTAssertEqual(deleted, 3)
        XCTAssertEqual(try history.count(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedOld.path), "imported folders are never deleted")
        XCTAssertEqual(try history.ledgerRows().count, 4, "stats survive retention")
    }

    func testRecordingStoreAppliesTheSetting() throws {
        let now = Date()
        try addRecording(daysAgo: 3, now: now)
        try addRecording(daysAgo: 20, now: now)

        let services = AppServices(vocabulary: VocabularyManager(storageURL: root.appendingPathComponent("vocabulary.json")))
        services.paths = AppPaths(root: root)
        services.settings = makeSettings()
        services.history = history
        services.recordings.start(services: services)

        services.settings?.history.historyRetentionDays = 0
        XCTAssertEqual(services.recordings.applyRetention(), 0)
        XCTAssertEqual(try history.count(), 2)

        services.settings?.history.historyRetentionDays = 7
        XCTAssertEqual(services.recordings.applyRetention(), 1)
        XCTAssertEqual(try history.count(), 1)
        XCTAssertTrue(services.stats is HistoryStatsService, "start registers the stats service")
    }
}
