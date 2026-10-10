import XCTest

@testable import Parrot

/// The one-file-per-mode store: migration from the legacy `modes.json`,
/// presets on a fresh install, order, selection and safe deletes. Every
/// test uses a temporary root and its own defaults suite.
final class ModeMigrationTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-modemigration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ParrotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var paths: AppPaths { AppPaths(root: root) }

    private func makeManager() -> ModeManager {
        ModeManager(paths: paths, defaults: defaults)
    }

    private func modeFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.modes.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    /// A list in the shape builds before the full schema wrote.
    private func writeLegacy(_ objects: [[String: Any]]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: objects)
        try data.write(to: paths.legacyModesFile)
        return data
    }

    private let generalID = UUID()
    private let mailID = UUID()

    private func legacyObjects() -> [[String: Any]] {
        [
            ["id": generalID.uuidString, "name": "General", "description": "Default dictation mode", "isDefault": true],
            ["id": mailID.uuidString, "name": "Mail", "description": "", "isDefault": false,
             "refinementPrompt": "Format as an email", "appBundleIDs": ["com.apple.mail"]],
        ]
    }

    // MARK: - Migration

    func testLegacyListMigratesToOneFilePerMode() throws {
        let original = try writeLegacy(legacyObjects())
        defaults.set(mailID.uuidString, forKey: "Parrot.selectedModeID")

        let manager = makeManager()

        let generalKey = generalID.uuidString.lowercased()
        let mailKey = mailID.uuidString.lowercased()
        XCTAssertEqual(modeFiles(), ["\(generalKey).json", "\(mailKey).json"].sorted())
        XCTAssertEqual(manager.modes.map(\.key), [generalKey, mailKey])
        XCTAssertEqual(defaults.stringArray(forKey: "parrot.llm.modeOrder"), [generalKey, mailKey])
        XCTAssertFalse(manager.isFreshInstall)
        XCTAssertFalse(manager.didSeedPresets)

        // The user's choice carries over to the new key.
        XCTAssertEqual(manager.selectedMode.id, mailID)
        XCTAssertEqual(defaults.string(forKey: "parrot.llm.lastSelectedModeKey"), mailKey)
        XCTAssertEqual(defaults.string(forKey: "parrot.llm.activeModeKey"), mailKey)

        // Fields survive and destination context stays on as before.
        let mail = try XCTUnwrap(manager.mode(forKey: mailKey))
        XCTAssertEqual(mail.refinementPrompt, "Format as an email")
        XCTAssertEqual(mail.appBundleIDs, ["com.apple.mail"])
        XCTAssertTrue(mail.contextFromActiveApplication)
        XCTAssertTrue(mail.contextFromSelection)
        XCTAssertFalse(mail.contextFromClipboard)

        // The original is backed up byte for byte and never deleted.
        let backup = paths.legacyModesFile.appendingPathExtension("bak")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.legacyModesFile.path))

        // Each file holds its own mode, keyed by its file name.
        let fileData = try Data(contentsOf: paths.modes.appendingPathComponent("\(mailKey).json"))
        let decoded = try JSONDecoder().decode(Mode.self, from: fileData)
        XCTAssertEqual(decoded.id, mailID)
        XCTAssertEqual(decoded.key, mailKey)
    }

    func testMigrationIsIdempotent() throws {
        let original = try writeLegacy(legacyObjects())

        let first = makeManager()
        let firstModes = first.modes
        let second = makeManager()

        XCTAssertEqual(second.modes, firstModes)
        XCTAssertEqual(modeFiles().count, 2)
        XCTAssertFalse(second.didSeedPresets)
        XCTAssertEqual(
            try Data(contentsOf: paths.legacyModesFile.appendingPathExtension("bak")), original,
            "the backup keeps the pre-migration bytes"
        )
    }

    func testExplicitLegacyContextTogglesAreKept() throws {
        var objects = legacyObjects()
        objects[0]["contextFromActiveApplication"] = false
        objects[0]["contextFromSelection"] = false
        _ = try writeLegacy(objects)

        let manager = makeManager()

        XCTAssertFalse(manager.modes[0].contextFromActiveApplication)
        XCTAssertFalse(manager.modes[0].contextFromSelection)
    }

    func testLegacyFileStaysCurrentAsMirror() throws {
        _ = try writeLegacy(legacyObjects())
        let manager = makeManager()

        var mail = manager.modes[1]
        mail.tone = .formal
        manager.updateMode(mail)

        let mirrored = try JSONDecoder().decode([Mode].self, from: Data(contentsOf: paths.legacyModesFile))
        XCTAssertEqual(mirrored.map(\.id), [generalID, mailID])
        XCTAssertEqual(mirrored[1].tone, .formal)
    }

    func testUnreadableLegacyFileIsBackedUp() throws {
        try Data("not json".utf8).write(to: paths.legacyModesFile)

        let manager = makeManager()

        XCTAssertTrue(manager.didSeedPresets)
        let backup = paths.legacyModesFile.appendingPathExtension("unreadable.bak")
        XCTAssertEqual(try Data(contentsOf: backup), Data("not json".utf8))
    }

    // MARK: - Fresh Install

    func testFreshInstallSeedsPresets() {
        let manager = makeManager()

        XCTAssertEqual(manager.modes.map(\.key), ["super", "voice", "message", "email", "note", "meeting"])
        XCTAssertEqual(manager.modes.map(\.type), [.super, .voice, .message, .email, .note, .meeting])
        XCTAssertEqual(manager.selectedMode.key, "super")
        XCTAssertTrue(manager.didSeedPresets)
        XCTAssertFalse(manager.isFreshInstall, "AppState must not replace the presets")
        XCTAssertEqual(modeFiles(), ["email.json", "meeting.json", "message.json", "note.json", "super.json", "voice.json"])
    }

    func testWithoutPresetsAFreshStoreIsFlagged() {
        let manager = ModeManager(
            modesDirectory: paths.modes, legacyFileURL: paths.legacyModesFile,
            defaults: defaults, seedsPresets: false
        )
        XCTAssertTrue(manager.isFreshInstall)
        XCTAssertEqual(manager.modes.count, 1)
    }

    // MARK: - Order, Add, Upsert, Remove

    func testOrderPersistsAcrossLaunches() {
        let manager = makeManager()
        let reversed = Array(manager.modeOrder.reversed())
        manager.setOrder(reversed)

        XCTAssertEqual(makeManager().modeOrder, reversed)
    }

    func testAddingAPresetTwiceGetsAUniqueKey() {
        let manager = makeManager()
        let copy = manager.addPreset(.email)

        XCTAssertEqual(copy.key, "email-2")
        XCTAssertEqual(manager.modes.last?.key, "email-2")
        XCTAssertTrue(modeFiles().contains("email-2.json"))
    }

    func testAddModeSanitizesUnsafeKeys() {
        let manager = makeManager()
        let added = manager.addMode(Mode(key: "../evil/name", name: "Evil"))

        XCTAssertEqual(added.key, "-evil-name")
        XCTAssertTrue(modeFiles().contains("-evil-name.json"))
    }

    func testKeysAreUniqueIgnoringCase() {
        let manager = makeManager()
        let added = manager.addMode(Mode(key: "SUPER", name: "Shouty"))
        XCTAssertEqual(added.key, "SUPER-2")
    }

    func testUpsertUpdatesByKeyKeepingIDAndPosition() throws {
        let manager = makeManager()
        let original = try XCTUnwrap(manager.mode(forKey: "email"))
        let index = try XCTUnwrap(manager.modes.firstIndex { $0.key == "email" })

        var incoming = Mode(key: "email", name: "Work Email", type: .email)
        incoming.refinementPrompt = "Sign every email with Tim."
        let stored = manager.upsertMode(incoming)

        XCTAssertEqual(stored.id, original.id)
        XCTAssertEqual(manager.modes[index].name, "Work Email")
        XCTAssertEqual(manager.modes[index].refinementPrompt, "Sign every email with Tim.")
        XCTAssertEqual(manager.modes.count, 6)

        let added = manager.upsertMode(Mode(key: "imported-code", name: "Code"))
        XCTAssertEqual(added.key, "imported-code")
        XCTAssertEqual(manager.modes.count, 7)
    }

    func testRemovedModeFileMovesAsideInsteadOfBeingDeleted() throws {
        let manager = makeManager()
        let note = try XCTUnwrap(manager.mode(forKey: "note"))
        manager.removeMode(id: note.id)

        XCTAssertFalse(modeFiles().contains("note.json"))
        let trash = paths.modes.appendingPathComponent(".deleted")
        let kept = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("note-"))
        XCTAssertNil(makeManager().mode(forKey: "note"))
    }

    func testDamagedModeFileIsNeverOverwritten() throws {
        _ = makeManager()
        let damaged = paths.modes.appendingPathComponent("broken.json")
        try Data("{ not a mode".utf8).write(to: damaged)

        let manager = makeManager()
        let added = manager.addMode(Mode(key: "broken", name: "Broken"))

        XCTAssertEqual(added.key, "broken-2")
        XCTAssertEqual(try Data(contentsOf: damaged), Data("{ not a mode".utf8))
    }

    // MARK: - Selection and Activation

    func testActivationLastsUntilReturn() throws {
        let manager = makeManager()
        let email = try XCTUnwrap(manager.mode(forKey: "email"))

        manager.activate(email)
        XCTAssertEqual(manager.activeModeKey, "email")
        XCTAssertEqual(manager.activeMode.key, "email")
        XCTAssertEqual(manager.selectedMode.key, "super", "activation never changes the user's choice")

        manager.returnToLastSelected()
        XCTAssertEqual(manager.activeModeKey, "super")
    }

    func testSelectModePersistsBothKeys() throws {
        let manager = makeManager()
        let note = try XCTUnwrap(manager.mode(forKey: "note"))
        manager.selectMode(note)

        XCTAssertEqual(defaults.string(forKey: "parrot.llm.lastSelectedModeKey"), "note")
        XCTAssertEqual(defaults.string(forKey: "parrot.llm.activeModeKey"), "note")
        XCTAssertEqual(defaults.string(forKey: "Parrot.selectedModeID"), note.id.uuidString)
        XCTAssertEqual(makeManager().selectedMode.key, "note")
    }

    // MARK: - Live Reload

    func testOutsideEditReloads() throws {
        let manager = makeManager()
        let url = paths.modes.appendingPathComponent("message.json")
        var message = try JSONDecoder().decode(Mode.self, from: Data(contentsOf: url))
        message.name = "Chat"
        try JSONEncoder().encode(message).write(to: url)

        manager.reloadFromDisk()

        XCTAssertEqual(manager.mode(forKey: "message")?.name, "Chat")
    }

    func testMissingSelectedFileFallsBackToAnAvailableMode() throws {
        let manager = makeManager()
        let note = try XCTUnwrap(manager.mode(forKey: "note"))
        manager.selectMode(note)
        try FileManager.default.removeItem(at: paths.modes.appendingPathComponent("note.json"))

        manager.reloadFromDisk()

        XCTAssertNil(manager.mode(forKey: "note"))
        XCTAssertEqual(manager.selectedMode.key, "super")
        XCTAssertEqual(manager.activeModeKey, "super")
    }

    // MARK: - Language Models

    func testUseInAllModesSkipsVoice() {
        let manager = makeManager()
        manager.useLanguageModelEverywhere("groq/llama-3.3-70b-versatile")

        XCTAssertEqual(manager.mode(forKey: "voice")?.languageModelID, "")
        XCTAssertEqual(manager.modes(usingLanguageModel: "groq/llama-3.3-70b-versatile").count, 5)

        manager.clearLanguageModel("groq/llama-3.3-70b-versatile")
        XCTAssertTrue(manager.modes(usingLanguageModel: "groq/llama-3.3-70b-versatile").isEmpty)
    }
}
