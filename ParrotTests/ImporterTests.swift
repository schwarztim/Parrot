import CryptoKit
import XCTest

@testable import Parrot

/// The Superwhisper importer against a synthetic app folder built here from
/// the spec's schema: counts, mapping, privacy, read-only source, dry run
/// and an idempotent re-run.
@MainActor
final class ImporterTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var suiteName: String!
    private var history: HistoryStore!
    private var vocabulary: VocabularyManager!
    private var modes: ModeManager!
    private var settings: AppSettings!

    private let toggleJSON = "{\"carbonKeyCode\":2,\"carbonModifiers\":768}"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-import-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Documents/superwhisper", isDirectory: true)
        try buildSuperwhisperTree()

        suiteName = "parrot-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        let parrot = root.appendingPathComponent("Parrot", isDirectory: true)
        try FileManager.default.createDirectory(at: parrot, withIntermediateDirectories: true)
        history = try HistoryStore(databaseURL: parrot.appendingPathComponent("parrot.db"))
        vocabulary = VocabularyManager(storageURL: parrot.appendingPathComponent("vocabulary.json"))
        vocabulary.merge([.word("Parrot")])
        modes = ModeManager(storageURL: parrot.appendingPathComponent("modes.json"), defaults: defaults)
        modes.replaceAll([Mode(name: "Default", isDefault: true), Mode(name: "email")])
    }

    override func tearDown() async throws {
        history = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Synthetic Tree

    private func write(_ text: String, to path: String) throws {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func buildSuperwhisperTree() throws {
        try write("""
            {"vocabulary": ["Parrot", "Kubernetes", "kubernetes", "btw"],
             "replacements": [{"id": "r1", "original": "btw", "with": "by the way"},
                              {"id": "r2", "original": "my email", "with": "someone@example.com"}],
             "modeKeys": ["email", "super", "voice"],
             "favoriteModelIDs": []}
            """, to: "settings/settings.json")
        try write("""
            {"key": "super", "name": "Super", "iconName": "sparkles", "description": "", "type": "super",
             "version": 3, "voiceModelID": "sw-ultra-cloud-v1-east", "languageModelID": "sw-claude-4p5-haiku",
             "language": "en", "translateToEnglish": false, "literalPunctuation": true, "realtimeOutput": false,
             "diarize": false, "useSystemAudio": false, "prompt": "Tidy the text.",
             "promptExamples": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "input": "um hi", "output": "Hi."}],
             "contextTemplate": "", "contextFromSelection": true, "contextFromClipboard": false,
             "contextFromActiveApplication": true, "activationApps": ["com.apple.mail", "Unknown App"],
             "activationSites": ["github.com"], "script": "", "scriptEnabled": false,
             "smartCapitalization": false, "pauseMediaPlayback": true, "tone": "formal",
             "shortcut": {"carbonKeyCode": 18, "carbonModifiers": 2048}}
            """, to: "modes/super.json")
        try write("""
            {"key": "email", "name": "Email", "type": "email", "prompt": "", "activationApps": []}
            """, to: "modes/email.json")
        try write("""
            {"key": "voice", "name": "Plain Voice", "type": "voice", "prompt": "ignored for voice"}
            """, to: "modes/voice.json")
        try write("{ not json", to: "modes/broken.json")

        try write("""
            {"datetime": "2023-11-14T17:13:20", "appVersion": "2.18.4", "modelKey": "sw-ultra-cloud-v1-east",
             "modelName": "Ultra Legacy (Cloud)", "languageModelKey": "sw-claude-4p5-haiku",
             "languageModelName": "Haiku 4.5", "duration": 4000, "processingTime": 0,
             "languageModelProcessingTime": 850, "recordingDevice": "MacBook Pro Microphone",
             "languageSelected": "en", "literalPunctuationEnabled": false, "translationEnabled": false,
             "realtimeEnabled": false, "separateSpeakersEnabled": true, "systemAudioEnabled": false,
             "applicationContextEnabled": true, "rawResult": "we were running late",
             "llmResult": "We were running late!", "result": "We were running late.",
             "prompt": "SECRET-PROMPT-TEXT",
             "promptContext": {"applicationContext": {"name": "Mail", "selectedText": "SECRET-SELECTION"},
                               "systemContext": {"clipboard": "SECRET-CLIPBOARD", "computerName": "SECRET-HOST"},
                               "userContext": {"fullName": "SECRET-NAME"}},
             "modeName": "Super",
             "segments": [{"text": "we were", "start": 0, "end": 1.5, "speaker": 0},
                          {"text": "running late", "start": 1.5, "end": 3.2, "confidence": 0.9, "speaker": 1}],
             "speakers": [{"name": "Alex", "number": 0}, {"name": "Sam", "number": 1}]}
            """, to: "recordings/1700000000/meta.json")
        try write("RIFF fake wav", to: "recordings/1700000000/output.wav")
        try write("""
            {"datetime": "2023-11-14T17:15:00", "duration": 1200, "processingTime": 300,
             "rawResult": "raw words only", "result": "", "segments": [], "speakers": []}
            """, to: "recordings/1700000100/meta.json")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("recordings/1700000200"), withIntermediateDirectories: true)
        try write("RIFF fake wav", to: "recordings/1700000300/output.wav")
        try write("{ corrupt", to: "recordings/1700000400/meta.json")
        try write("""
            {"rawResult": "", "result": "  ", "segments": [], "speakers": []}
            """, to: "recordings/1700000500/meta.json")
        try write("", to: "recordings/.DS_Store")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("recordings/notes"), withIntermediateDirectories: true)
    }

    /// Path, size, modification date and content hash of every file.
    private func fingerprint() throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
            var line = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if values.isDirectory != true {
                let digest = SHA256.hash(data: try Data(contentsOf: url))
                line += " \(values.fileSize ?? 0) " + digest.map { String(format: "%02x", $0) }.joined()
            }
            result[url.path.replacingOccurrences(of: source.path, with: "")] = line
        }
        return result
    }

    private func importer(shortcuts: [String: Any] = [:]) -> SuperwhisperImporter {
        SuperwhisperImporter(
            sourceFolder: source,
            resolveAppName: { $0 == "Mail" ? "com.apple.mail" : nil },
            shortcutDefaults: { shortcuts }
        )
    }

    private var targets: SuperwhisperImporter.Targets {
        SuperwhisperImporter.Targets(history: history, vocabulary: vocabulary, modes: modes, hotkeys: settings.hotkeys, retentionDays: 0)
    }

    private func run(_ options: SuperwhisperImporter.Options, shortcuts: [String: Any] = [:]) async -> SuperwhisperImporter.Report {
        let importer = importer(shortcuts: shortcuts)
        let scan = importer.scan(options: options)
        return await importer.apply(scan, options: options, to: targets)
    }

    // MARK: - Tests

    func testFullImportCountsAndRows() async throws {
        let before = try fingerprint()
        let report = await run(SuperwhisperImporter.Options())

        XCTAssertTrue(report.folderExists)
        XCTAssertEqual(report.recordingsFound, 6)
        XCTAssertEqual(report.recordingsImportable, 2)
        XCTAssertEqual(report.recordingsWithAudio, 1)
        XCTAssertEqual(report.recordingsImported, 2)
        XCTAssertEqual(report.skipped[.emptyFolder], 1)
        XCTAssertEqual(report.skipped[.missingMeta], 1)
        XCTAssertEqual(report.skipped[.corruptMeta], 1)
        XCTAssertEqual(report.skipped[.noText], 1)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")

        let entries = try history.entries()
        XCTAssertEqual(entries.count, 2)
        let first = try XCTUnwrap(entries.first { $0.sourceKey == "superwhisper:1700000000" })
        XCTAssertEqual(first.timestamp.timeIntervalSince1970, 1_700_000_000, "folder name is the timestamp")
        XCTAssertEqual(first.finalText, "We were running late.", "result is the final text")
        XCTAssertEqual(first.llmText, "We were running late!")
        XCTAssertEqual(first.rawTranscript, "we were running late")
        XCTAssertEqual(first.appName, "Mail")
        XCTAssertEqual(first.appBundleID, "com.apple.mail")
        XCTAssertEqual(first.modeName, "Super")
        XCTAssertEqual(first.duration, 4.0, accuracy: 0.0001, "milliseconds become seconds")
        XCTAssertEqual(first.llmProcessingTime, 0.85, accuracy: 0.0001)
        XCTAssertEqual(first.audioPath, source.appendingPathComponent("recordings/1700000000/output.wav").path, "audio referenced in place")
        XCTAssertEqual(first.folderPath, source.appendingPathComponent("recordings/1700000000").path)
        XCTAssertTrue(first.isImported)

        let second = try XCTUnwrap(entries.first { $0.sourceKey == "superwhisper:1700000100" })
        XCTAssertEqual(second.finalText, "raw words only", "falls back to raw when result and llmResult are empty")
        XCTAssertNil(second.audioPath)

        XCTAssertEqual(try history.entries(matching: "running").count, 1, "search index rebuilt after the batch")

        // Lazy detail load reads segments and speakers, never the prompt.
        let details = try XCTUnwrap(RecordingDetails.load(for: first))
        XCTAssertEqual(details.segments.map(\.speaker), ["Alex", "Sam"])
        XCTAssertEqual(details.speakers, ["Alex", "Sam"])
        XCTAssertNil(details.renderedPrompt)

        XCTAssertEqual(try fingerprint(), before, "the Superwhisper folder is never modified")
    }

    func testPromptAndContextNeverStored() async throws {
        _ = await run(SuperwhisperImporter.Options())
        let db = try Data(contentsOf: root.appendingPathComponent("Parrot/parrot.db"))
        let text = String(decoding: db, as: UTF8.self)
        for secret in ["SECRET-PROMPT-TEXT", "SECRET-SELECTION", "SECRET-CLIPBOARD", "SECRET-HOST", "SECRET-NAME"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into the database")
            XCTAssertEqual(try history.count(matching: secret), 0)
        }
        let labels = Mirror(reflecting: try JSONDecoder().decode(
            Superwhisper.Meta.self,
            from: Data(contentsOf: source.appendingPathComponent("recordings/1700000000/meta.json"))
        )).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("prompt"))
        XCTAssertFalse(labels.contains("promptContext"))
    }

    func testModesMapAndDedupe() async throws {
        let report = await run(SuperwhisperImporter.Options(vocabulary: false, recordings: false))

        XCTAssertEqual(report.modesFound, 3)
        XCTAssertEqual(report.unreadableModes, 1)
        XCTAssertEqual(report.modesAlreadyPresent, 1, "Email matches the existing 'email' mode by name")
        XCTAssertEqual(report.modesImported, 2)
        XCTAssertEqual(report.unresolvedActivationApps, 1)

        let names = modes.modes.map(\.name)
        XCTAssertTrue(names.contains("Super"))
        XCTAssertTrue(names.contains("Plain Voice"))
        XCTAssertEqual(names.filter { $0.lowercased() == "email" }.count, 1)

        let superMode = try XCTUnwrap(modes.modes.first { $0.name == "Super" })
        XCTAssertEqual(superMode.type, .super)
        XCTAssertEqual(superMode.refinementPrompt, "Tidy the text.")
        XCTAssertEqual(superMode.promptExamples.map(\.output), ["Hi."])
        XCTAssertEqual(superMode.appBundleIDs, ["com.apple.mail"])
        XCTAssertEqual(superMode.activationSites, ["github.com"])
        XCTAssertEqual(superMode.language, "en")
        XCTAssertTrue(superMode.literalPunctuation)
        XCTAssertTrue(superMode.contextFromSelection)
        XCTAssertFalse(superMode.autocapitalizeInsert, "legacy smartCapitalization maps over")
        XCTAssertEqual(superMode.playbackBehavior, .pause, "legacy pauseMediaPlayback maps over")
        XCTAssertEqual(superMode.tone, .formal)
        XCTAssertEqual(superMode.voiceModelID, "", "Superwhisper model ids are not carried over")
        XCTAssertEqual(superMode.languageModelID, "")
        XCTAssertNil(superMode.shortcut, "shortcuts are opt-in")

        let voice = try XCTUnwrap(modes.modes.first { $0.name == "Plain Voice" })
        XCTAssertNil(voice.refinementPrompt, "voice modes have no language model step")
    }

    func testModeShortcutOnlyWhenOptedIn() throws {
        let data = try Data(contentsOf: source.appendingPathComponent("modes/super.json"))
        let file = try JSONDecoder().decode(Superwhisper.ModeFile.self, from: data)
        XCTAssertNil(SuperwhisperImporter.mode(from: file, includeShortcut: false, resolveActivationApp: { $0 }).mode.shortcut)
        let withShortcut = SuperwhisperImporter.mode(from: file, includeShortcut: true, resolveActivationApp: { $0 }).mode.shortcut
        XCTAssertEqual(withShortcut, SuperwhisperShortcut.modeShortcut(carbonKeyCode: 18, carbonModifiers: 2048))
    }

    func testVocabularyDedupesAndReplacementWins() async throws {
        let report = await run(SuperwhisperImporter.Options(modes: false, recordings: false))

        XCTAssertEqual(report.vocabularyFound, 4)
        XCTAssertEqual(report.replacementsFound, 2)
        XCTAssertEqual(report.replacementsImported, 2)
        XCTAssertEqual(report.wordsImported, 1, "only Kubernetes is new")
        XCTAssertEqual(report.vocabularyDuplicates, 3, "Parrot exists, kubernetes repeats, btw is a replacement")

        XCTAssertEqual(Set(vocabulary.words.map(\.original)), ["Parrot", "Kubernetes"])
        XCTAssertEqual(vocabulary.replacements.first { $0.original == "btw" }?.replacement, "by the way")
    }

    func testShortcutsAreOptIn() async throws {
        let defaults: [String: Any] = [
            "KeyboardShortcuts_toggleRecording": toggleJSON,
            "KeyboardShortcuts_notAShortcutName": toggleJSON,
            "appFolderDirectory": "/tmp",
        ]
        let original = settings.hotkeys.shortcut(for: .toggleRecording)

        let off = await run(SuperwhisperImporter.Options(modes: false, vocabulary: false, recordings: false), shortcuts: defaults)
        XCTAssertEqual(off.shortcutsImported, 0)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .toggleRecording), original)

        let dry = await run(SuperwhisperImporter.Options(modes: false, vocabulary: false, recordings: false, shortcuts: true, dryRun: true), shortcuts: defaults)
        XCTAssertEqual(dry.shortcutsFound, 1)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .toggleRecording), original, "a dry run sets nothing")

        let on = await run(SuperwhisperImporter.Options(modes: false, vocabulary: false, recordings: false, shortcuts: true), shortcuts: defaults)
        XCTAssertEqual(on.shortcutsImported, 1)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .toggleRecording), SuperwhisperShortcut.shortcut(fromJSON: toggleJSON))
    }

    func testDryRunOnlyCounts() async throws {
        let wordsBefore = vocabulary.entries
        let modesBefore = modes.modes.map(\.name)
        let report = await run(SuperwhisperImporter.Options(dryRun: true))

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.recordingsImported, 2, "would import")
        XCTAssertEqual(report.modesImported, 2, "would import")
        XCTAssertEqual(report.replacementsImported, 2)
        XCTAssertEqual(try history.count(), 0)
        XCTAssertEqual(vocabulary.entries, wordsBefore)
        XCTAssertEqual(modes.modes.map(\.name), modesBefore)
        XCTAssertFalse(report.lines.joined().contains("running late"), "the report holds counts only")
    }

    func testRerunIsIdempotent() async throws {
        _ = await run(SuperwhisperImporter.Options())
        let modeCount = modes.modes.count
        let vocabularyCount = vocabulary.entries.count

        let again = await run(SuperwhisperImporter.Options())
        XCTAssertEqual(again.recordingsImported, 0)
        XCTAssertEqual(again.recordingsAlreadyImported, 2)
        XCTAssertEqual(again.modesImported, 0)
        XCTAssertEqual(again.wordsImported + again.replacementsImported, 0)
        XCTAssertEqual(try history.count(), 2)
        XCTAssertEqual(modes.modes.count, modeCount)
        XCTAssertEqual(vocabulary.entries.count, vocabularyCount)
    }

    func testRetentionWarningCountsOldImports() async throws {
        let importer = importer()
        let options = SuperwhisperImporter.Options(modes: false, vocabulary: false, dryRun: true)
        var targets = targets
        targets.retentionDays = 30
        let report = await importer.apply(importer.scan(options: options), options: options, to: targets,
                                          now: Date(timeIntervalSince1970: 1_700_000_000 + 40 * 86_400))
        XCTAssertEqual(report.olderThanRetention, 2)
    }

    func testDeletingAnImportedRecordingKeepsItsFolder() async throws {
        _ = await run(SuperwhisperImporter.Options(modes: false, vocabulary: false))
        try history.deleteAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("recordings/1700000000/output.wav").path))
    }

    func testMissingFolderReports() async {
        let importer = SuperwhisperImporter(sourceFolder: root.appendingPathComponent("nope"), resolveAppName: nil, shortcutDefaults: { [:] })
        let options = SuperwhisperImporter.Options()
        let report = await importer.apply(importer.scan(options: options), options: options, to: targets)
        XCTAssertFalse(report.folderExists)
        XCTAssertEqual(report.errors, ["Superwhisper folder not found"])
    }

    func testDefaultSourceFolder() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(SuperwhisperImporter.defaultSourceFolder(appFolderDirectory: nil, home: home).path, "/Users/someone/Documents/superwhisper")
        XCTAssertEqual(SuperwhisperImporter.defaultSourceFolder(appFolderDirectory: "", home: home).path, "/Users/someone/Documents/superwhisper")
        XCTAssertEqual(SuperwhisperImporter.defaultSourceFolder(appFolderDirectory: "/Users/someone/Documents", home: home).path, "/Users/someone/Documents/superwhisper")
        XCTAssertEqual(SuperwhisperImporter.defaultSourceFolder(appFolderDirectory: "~/Dropbox", home: home).path, "/Users/someone/Dropbox/superwhisper")
        XCTAssertEqual(SuperwhisperImporter.defaultSourceFolder(appFolderDirectory: "/Volumes/Data/superwhisper", home: home).path, "/Volumes/Data/superwhisper")
        XCTAssertEqual(SuperwhisperImporter.defaultSourceFolder(appFolderDirectory: "file:///Users/someone/Sync/", home: home).path, "/Users/someone/Sync/superwhisper")
    }

    func testActivationAppResolution() {
        XCTAssertEqual(AppResolver.bundleID(forActivationApp: "com.apple.mail"), "com.apple.mail")
        XCTAssertTrue(AppResolver.looksLikeBundleID("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(AppResolver.looksLikeBundleID("Visual Studio Code"))
        XCTAssertFalse(AppResolver.looksLikeBundleID("Mail"))
        XCTAssertNil(AppResolver.bundleID(forActivationApp: "Definitely Not An Installed App 123"))
    }
}
