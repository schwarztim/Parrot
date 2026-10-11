import XCTest

@testable import Parrot

/// The mode schema: files written before the full field set existed still
/// decode with defaults, and a mode with every field set round trips.
final class ModeSchemaTests: XCTestCase {

    /// The six fields ModeManager wrote before the schema grew, encoded the
    /// same way (synthesized Codable, nil optionals omitted).
    private struct LegacyMode: Codable {
        var id: UUID
        var name: String
        var description: String
        var isDefault: Bool
        var refinementPrompt: String?
        var appBundleIDs: [String]?
    }

    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModeSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "ModeSchemaTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Legacy

    func testLegacyJSONDecodesWithDefaults() throws {
        let general = LegacyMode(id: UUID(), name: "General", description: "Default dictation mode", isDefault: true)
        let mail = LegacyMode(
            id: UUID(), name: "Mail", description: "", isDefault: false,
            refinementPrompt: "Format as an email", appBundleIDs: ["com.apple.mail"]
        )
        let data = try JSONEncoder().encode([general, mail])

        let modes = try JSONDecoder().decode([Mode].self, from: data)

        XCTAssertEqual(modes.count, 2)
        let first = modes[0]
        XCTAssertEqual(first.id, general.id)
        XCTAssertEqual(first.name, "General")
        XCTAssertEqual(first.description, "Default dictation mode")
        XCTAssertTrue(first.isDefault)
        XCTAssertNil(first.refinementPrompt)
        XCTAssertNil(first.appBundleIDs)

        // Every new field takes its default.
        XCTAssertEqual(first.key, general.id.uuidString.lowercased())
        XCTAssertEqual(first.type, .custom)
        XCTAssertEqual(first.iconName, "")
        XCTAssertEqual(first.voiceModelID, "")
        XCTAssertEqual(first.language, "auto")
        XCTAssertFalse(first.translateToEnglish)
        XCTAssertFalse(first.literalPunctuation)
        XCTAssertFalse(first.realtimeOutput)
        XCTAssertFalse(first.diarize)
        XCTAssertFalse(first.useSystemAudio)
        XCTAssertEqual(first.languageModelID, "")
        XCTAssertNil(first.tone)
        XCTAssertEqual(first.promptExamples, [])
        XCTAssertEqual(first.contextTemplate, "")
        XCTAssertFalse(first.contextFromSelection)
        XCTAssertFalse(first.contextFromClipboard)
        XCTAssertFalse(first.contextFromActiveApplication)
        XCTAssertEqual(first.activationSites, [])
        XCTAssertEqual(first.script, "")
        XCTAssertFalse(first.scriptEnabled)
        XCTAssertNil(first.autoPaste)
        XCTAssertTrue(first.autocapitalizeInsert)
        XCTAssertNil(first.playbackBehavior)
        XCTAssertNil(first.shortcut)
        XCTAssertEqual(first.version, 1)

        let second = modes[1]
        XCTAssertEqual(second.refinementPrompt, "Format as an email")
        XCTAssertEqual(second.appBundleIDs, ["com.apple.mail"])
        XCTAssertEqual(second.key, mail.id.uuidString.lowercased())
    }

    /// A legacy file on disk still loads through ModeManager, and the next
    /// save writes the new fields.
    func testModeManagerLoadsLegacyFileAndWritesNewFields() throws {
        let legacy = LegacyMode(id: UUID(), name: "Old", description: "", isDefault: true)
        let url = tempDir.appendingPathComponent("modes.json")
        try JSONEncoder().encode([legacy]).write(to: url)

        let manager = ModeManager(storageURL: url, defaults: defaults)
        XCTAssertFalse(manager.isFreshInstall)
        XCTAssertEqual(manager.selectedMode.id, legacy.id)
        XCTAssertEqual(manager.selectedMode.language, "auto")

        var edited = manager.selectedMode
        edited.tone = .formal
        manager.updateMode(edited)

        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        )
        XCTAssertEqual(saved.first?["tone"] as? String, "formal")
        XCTAssertEqual(saved.first?["key"] as? String, legacy.id.uuidString.lowercased())
        XCTAssertEqual(saved.first?["autocapitalizeInsert"] as? Bool, true)
        XCTAssertEqual(saved.first?["version"] as? Int, 1)
    }

    // MARK: - Full Schema

    func testFullModeRoundTrips() throws {
        let mode = Self.fullMode()

        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)

        XCTAssertEqual(decoded, mode)
    }

    func testFullModeEncodesEveryField() throws {
        let data = try JSONEncoder().encode(Self.fullMode())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let expected: Set<String> = [
            "id", "key", "name", "description", "isDefault", "type", "iconName",
            "voiceModelID", "language", "translateToEnglish", "literalPunctuation",
            "realtimeOutput", "diarize", "useSystemAudio",
            "languageModelID", "tone", "refinementPrompt", "promptExamples",
            "contextTemplate", "contextFromSelection", "contextFromClipboard", "contextFromActiveApplication",
            "appBundleIDs", "activationSites",
            "script", "scriptEnabled", "autoPaste", "autocapitalizeInsert",
            "playbackBehavior", "shortcut", "version",
        ]
        XCTAssertEqual(Set(json.keys), expected)
        XCTAssertEqual(json["type"] as? String, "email")
        XCTAssertEqual(json["tone"] as? String, "semi-formal")
        XCTAssertEqual(json["playbackBehavior"] as? String, "duck")
        XCTAssertEqual(json["key"] as? String, "email-work")
    }

    func testRawValuesMatchTheSpec() {
        XCTAssertEqual(ModeType.allCases.map(\.rawValue), ["super", "voice", "message", "email", "note", "meeting", "custom"])
        XCTAssertEqual(Tone.allCases.map(\.rawValue), ["casual", "semi-casual", "balanced", "semi-formal", "formal"])
        XCTAssertEqual(PlaybackBehavior.allCases.map(\.rawValue), ["keepPlaying", "pause", "duck", "mute"])
    }

    func testDefaultInitKeepsLegacyCallSites() {
        let id = UUID()
        let mode = Mode(id: id, name: "A", description: "d", isDefault: true, refinementPrompt: "p", appBundleIDs: ["x"])
        XCTAssertEqual(mode.key, id.uuidString.lowercased())
        XCTAssertEqual(mode.type, .custom)
        XCTAssertTrue(mode.autocapitalizeInsert)
        XCTAssertEqual(mode.version, Mode.currentVersion)
    }

    // MARK: - Fixtures

    private static func fullMode() -> Mode {
        Mode(
            id: UUID(),
            key: "email-work",
            name: "Work Email",
            description: "Replies at work",
            isDefault: false,
            type: .email,
            iconName: "envelope.fill",
            voiceModelID: "parakeet-v3",
            language: "en",
            translateToEnglish: true,
            literalPunctuation: true,
            realtimeOutput: true,
            diarize: true,
            useSystemAudio: true,
            languageModelID: "local-llama",
            tone: .semiFormal,
            refinementPrompt: "Write a short email.",
            promptExamples: [PromptExample(input: "hi bob thanks", output: "Hi Bob,\n\nThanks.")],
            contextTemplate: "Use this copied text:",
            contextFromSelection: true,
            contextFromClipboard: true,
            contextFromActiveApplication: true,
            appBundleIDs: ["com.apple.mail"],
            activationSites: ["mail.example.com"],
            script: "display dialog \"{{user_message}}\"",
            scriptEnabled: true,
            autoPaste: false,
            autocapitalizeInsert: false,
            playbackBehavior: .duck,
            shortcut: ModeShortcut(keyCode: 0x3D, modifiers: 1 << 20, mouseButton: 3),
            version: 1
        )
    }
}
