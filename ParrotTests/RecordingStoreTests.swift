import XCTest

@testable import Parrot

/// RecordingStore against a temp tree: meta.json writing from a finished
/// session, launch reconciliation (valid, corrupt, empty, audio-only and
/// orphan folders) and the folder deletion gate.
@MainActor
final class RecordingStoreTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var history: HistoryStore!

    private var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-recstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        suiteName = "parrot-recstore-\(UUID().uuidString)"
        history = try HistoryStore(databaseURL: root.appendingPathComponent("parrot.db"))
    }

    override func tearDown() async throws {
        history = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeServices() -> AppServices {
        let services = AppServices(vocabulary: VocabularyManager(storageURL: root.appendingPathComponent("vocabulary.json")))
        services.paths = AppPaths(root: root)
        services.settings = AppSettings(
            store: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            secrets: InMemorySecretStore()
        )
        services.history = history
        return services
    }

    @discardableResult
    private func makeFolder(_ name: String, meta: String? = nil, wav: Bool = false) throws -> URL {
        let folder = recordings.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let meta {
            try Data(meta.utf8).write(to: folder.appendingPathComponent("meta.json"))
        }
        if wav {
            try WavStreamWriter.header(dataBytes: 0).write(to: folder.appendingPathComponent("output.wav"))
        }
        return folder
    }

    private func validMeta(startedAt: Int, text: String) throws -> String {
        var meta = RecordingMeta(startedAt: Double(startedAt), finalText: text)
        meta.rawText = text.lowercased()
        meta.modeName = "Default"
        meta.duration = 3
        let data = try JSONEncoder().encode(meta)
        return String(decoding: data, as: UTF8.self)
    }

    private func finishedSession(folder: URL?, text: String = "Hello from Parrot") -> DictationSession {
        let session = DictationSession(trigger: .pushToTalk, mode: Mode(name: "Notes"))
        session.recordingFolder = folder
        session.rawTranscript = "hello from parrot"
        session.text = text
        session.llmText = text
        session.segments = [TranscriptSegment(text: "hello from parrot", start: 0, end: 1.5)]
        session.renderedPrompt = "SECRET PROMPT"
        session.timings = ["TranscribeStage": 0.4, "RefineStage": 1.2]
        session.outcome = .pasted
        return session
    }

    // MARK: - Save

    func testSaveWritesMetaBesideAudioAndIndexesIt() throws {
        let services = makeServices()
        let folder = try makeFolder("1700000000", wav: true)
        let session = finishedSession(folder: folder)

        services.recordings.save(session, services: services)

        let meta = try XCTUnwrap(try RecordingMeta.read(from: folder))
        XCTAssertEqual(meta.finalText, "Hello from Parrot")
        XCTAssertEqual(meta.rawText, "hello from parrot")
        XCTAssertEqual(meta.llmText, "Hello from Parrot")
        XCTAssertEqual(meta.modeName, "Notes")
        XCTAssertEqual(meta.segments.count, 1)
        XCTAssertEqual(meta.processingTime, 0.4, accuracy: 0.0001)
        XCTAssertEqual(meta.languageModelProcessingTime ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertNil(meta.renderedPrompt, "prompt is stored only with savePromptContext on")
        XCTAssertNil(meta.context)

        let entry = try XCTUnwrap(try history.entries().first)
        XCTAssertEqual(entry.sourceKey, "parrot:1700000000")
        XCTAssertEqual(entry.folderPath, folder.path)
        XCTAssertEqual(entry.audioPath, folder.appendingPathComponent("output.wav").path)
        XCTAssertEqual(entry.llmText, "Hello from Parrot")
        XCTAssertEqual(entry.rawWordCount, 3)
        XCTAssertFalse(entry.fromFile)
    }

    func testSavePromptContextStoresThePrompt() throws {
        let services = makeServices()
        services.settings?.history.savePromptContext = true
        let folder = try makeFolder("1700000001", wav: true)

        services.recordings.save(finishedSession(folder: folder), services: services)

        XCTAssertEqual(try RecordingMeta.read(from: folder)?.renderedPrompt, "SECRET PROMPT")
    }

    func testHistoryOffStoresNothingAndRemovesTheFolder() throws {
        let services = makeServices()
        services.settings?.history.historyEnabled = false
        let folder = try makeFolder("1700000002", wav: true)

        services.recordings.save(finishedSession(folder: folder), services: services)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try history.count(), 0)
    }

    func testDiscardedOutcomeKeepsAudioWithoutMeta() throws {
        let services = makeServices()
        let folder = try makeFolder("1700000003", wav: true)
        let session = finishedSession(folder: folder)
        session.outcome = .empty

        services.recordings.save(session, services: services)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("output.wav").path))
        XCTAssertNil(try RecordingMeta.read(from: folder))
        XCTAssertEqual(try history.count(), 0)
    }

    func testReprocessIsNeverSaved() throws {
        let services = makeServices()
        let session = DictationSession(trigger: .menu, mode: nil, source: .reprocess(42))
        session.text = "Reprocessed"
        session.outcome = .copiedOnly

        services.recordings.save(session, services: services)

        XCTAssertEqual(try history.count(), 0)
    }

    func testFileTranscriptionGetsItsOwnFolderAndIsFlagged() throws {
        let services = makeServices()
        let source = root.appendingPathComponent("talk.m4a")
        try Data([0]).write(to: source)
        let session = DictationSession(trigger: .menu, mode: nil, source: .file(source))
        session.text = "From a file"
        session.outcome = .copiedOnly

        services.recordings.save(session, services: services)

        let entry = try XCTUnwrap(try history.entries().first)
        XCTAssertTrue(entry.fromFile)
        XCTAssertEqual(entry.audioPath, source.path)
        let folder = URL(fileURLWithPath: try XCTUnwrap(entry.folderPath))
        XCTAssertEqual(try RecordingMeta.read(from: folder)?.fromFile, true)
        XCTAssertTrue(RecordingFolders.isOwned(folder, root: recordings))
    }

    // MARK: - Reconciliation

    func testReconcileInsertsSkipsAndDropsOrphans() throws {
        try makeFolder("1700000100", meta: try validMeta(startedAt: 1_700_000_100, text: "Valid one"), wav: true)
        try makeFolder("1700000101", meta: try validMeta(startedAt: 1_700_000_101, text: "Valid two"))
        try makeFolder("1700000102", meta: "{ this is not json")
        try makeFolder("1700000103", meta: "{\"rawText\": \"no final text\"}")
        try makeFolder("1700000104")                      // empty
        try makeFolder("1700000105", wav: true)           // audio only (discarded or empty)
        try makeFolder("notes")                           // not a recording folder

        // An orphan row (its folder is gone), an imported row and an old row.
        try history.insert(HistoryRecord(
            rawTranscript: "gone", finalText: "gone",
            folderPath: recordings.appendingPathComponent("1600000000").path,
            sourceKey: "parrot:1600000000"
        ))
        try history.insert(HistoryRecord(
            rawTranscript: "imported", finalText: "imported",
            folderPath: "/nonexistent/superwhisper/recordings/1500000000",
            sourceKey: "superwhisper:1500000000"
        ))
        try history.insert(rawTranscript: "old row", finalText: "old row", appBundleID: nil, modeName: nil)

        let report = RecordingStore.reconcile(root: recordings, history: history)

        XCTAssertEqual(report.scanned, 6)
        XCTAssertEqual(report.inserted, 2)
        XCTAssertEqual(report.corrupt, 2)
        XCTAssertEqual(report.empty, 1)
        XCTAssertEqual(report.audioOnly, 1)
        XCTAssertEqual(report.orphansRemoved, 1)

        let keys = Set(try history.entries().compactMap(\.sourceKey))
        XCTAssertEqual(keys, ["parrot:1700000100", "parrot:1700000101", "superwhisper:1500000000"])
        XCTAssertEqual(try history.count(), 4)
        XCTAssertEqual(try history.entries(matching: "valid").count, 2)

        let withAudio = try XCTUnwrap(try history.entries().first { $0.sourceKey == "parrot:1700000100" })
        XCTAssertNotNil(withAudio.audioPath)
        XCTAssertEqual(withAudio.timestamp.timeIntervalSince1970, 1_700_000_100)

        // A second pass changes nothing.
        let again = RecordingStore.reconcile(root: recordings, history: history)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.alreadyIndexed, 2)
        XCTAssertEqual(again.orphansRemoved, 0)
        XCTAssertEqual(try history.count(), 4)
    }

    func testReconcileWithoutRecordingsFolderDropsNothing() throws {
        try history.insert(HistoryRecord(
            rawTranscript: "kept", finalText: "kept",
            folderPath: recordings.appendingPathComponent("1600000000").path,
            sourceKey: "parrot:1600000000"
        ))
        let report = RecordingStore.reconcile(root: root.appendingPathComponent("missing"), history: history)
        XCTAssertEqual(report, RecordingStore.ReconcileReport())
        XCTAssertEqual(try history.count(), 1)
    }

    // MARK: - Deletion Gate

    func testDeleteRemovesOwnedFoldersOnly() throws {
        let owned = try makeFolder("1700000200", wav: true)
        let outside = root.appendingPathComponent("elsewhere/1700000201", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let ownedRow = try history.insert(HistoryRecord(
            rawTranscript: "a", finalText: "a", folderPath: owned.path, sourceKey: "parrot:1700000200"))
        let outsideRow = try history.insert(HistoryRecord(
            rawTranscript: "b", finalText: "b", folderPath: outside.path, sourceKey: "superwhisper:1700000201"))

        try history.delete(ids: [ownedRow.id, outsideRow.id])

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a folder outside recordings/ is never deleted")
        XCTAssertEqual(try history.count(), 0)
    }

    func testOwnershipGate() {
        XCTAssertTrue(RecordingFolders.isOwned(recordings.appendingPathComponent("1700000000"), root: recordings))
        XCTAssertFalse(RecordingFolders.isOwned(recordings.appendingPathComponent("notes"), root: recordings))
        XCTAssertFalse(RecordingFolders.isOwned(recordings, root: recordings))
        XCTAssertFalse(RecordingFolders.isOwned(recordings.appendingPathComponent("1/2"), root: recordings))
        XCTAssertFalse(RecordingFolders.isOwned(URL(fileURLWithPath: "/Users/x/Documents/superwhisper/recordings/1700000000"), root: recordings))
        XCTAssertFalse(RecordingFolders.isOwned(recordings.appendingPathComponent("../1700000000"), root: recordings))
    }

    // MARK: - Audio

    func testLoadSamplesReadsTheFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hello-parrot", withExtension: "wav", subdirectory: "Resources"))
        let samples = try XCTUnwrap(RecordingStore.loadSamples(from: url))
        XCTAssertGreaterThan(samples.count, 16_000 / 2)
    }
}
