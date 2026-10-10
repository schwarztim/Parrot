import XCTest

@testable import Parrot

/// ContextCaptureParticipant at recording start: the mode is made active,
/// the prompt is rendered with the context of that moment, the chips show
/// what will be sent, and everything is undone when the recording ends.
/// Uses a fake clipboard and a fake refiner; the only real read is the
/// frontmost app's name, which no assertion depends on.
@MainActor
final class ContextCaptureTests: XCTestCase {

    private final class RecordingRefiner: Refiner {
        var warmed: [String] = []
        func refine(_ text: String, modePrompt: String?, context: DictationContext?, settings: AppSettings) async throws -> String { text }
        func warmUpIfLocal(settings: AppSettings) {}
        func warmUp(languageModelID: String, settings: AppSettings) { warmed.append(languageModelID) }
    }

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var services: AppServices!
    private var probe: FakeClipboardProbe!
    private var refiner: RecordingRefiner!
    private var manager: ModeManager!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-contextcapture-\(UUID().uuidString)", isDirectory: true)
        suiteName = "ParrotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        settings.refinement.refinementEnabled = true
        settings.refinement.refinementProvider = .localServer
        settings.refinement.localServerModel = "test-model"

        services = AppServices(vocabulary: VocabularyManager(storageURL: root.appendingPathComponent("vocabulary.json")))
        services.settings = settings
        probe = FakeClipboardProbe()
        services.context = ContextService(clipboard: ClipboardWatcher(probe: probe))
        refiner = RecordingRefiner()
        services.refiner = refiner
        manager = ModeManager(paths: AppPaths(root: root), defaults: defaults)
        services.modes = manager
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        services = nil
        super.tearDown()
    }

    /// A mode that only asks for the clipboard, so nothing from the real
    /// screen ends up in the prompt.
    private func clipboardMode() throws -> Mode {
        var mode = try XCTUnwrap(manager.mode(forKey: "message"))
        mode.contextFromClipboard = true
        mode.contextFromSelection = false
        mode.contextFromActiveApplication = false
        manager.updateMode(mode)
        return try XCTUnwrap(manager.mode(forKey: "message"))
    }

    func testPromptIsRenderedAtStartWithTheRecentCopy() async throws {
        let mode = try clipboardMode()
        probe.copy("copied a moment ago")
        let session = DictationSession(trigger: .menu, mode: mode, source: .live)
        let participant = ContextCaptureParticipant(services: services)

        await participant.willStart(session)

        let prompt = try XCTUnwrap(session.prompt)
        XCTAssertTrue(prompt.system.hasPrefix(PromptRenderer.preamble))
        XCTAssertTrue(prompt.system.contains("USER CLIPBOARD CONTENT:"))
        XCTAssertTrue(prompt.system.contains("<<<copied a moment ago>>>"))
        XCTAssertEqual(prompt.user, RenderedPrompt.transcriptPlaceholder)
        XCTAssertEqual(session.renderedPrompt, prompt.fullText)
        XCTAssertEqual(services.live.clipboardChip, "copied a moment ago")
        XCTAssertNil(services.live.selectionChip)
        XCTAssertEqual(manager.activeModeKey, "message")
        XCTAssertEqual(manager.selectedMode.key, "super")
        XCTAssertEqual(refiner.warmed, [""])

        session.outcome = .pasted
        participant.didFinish(session)

        XCTAssertNil(services.live.clipboardChip)
        XCTAssertEqual(manager.activeModeKey, "super", "back to the user's own choice")
    }

    func testCloudModelWithLocalOnlyContextKeepsTheClipboardHere() async throws {
        settings.refinement.refinementProvider = .openAI
        settings.credentials.setKey("test-openai-key", for: .openAI)
        let mode = try clipboardMode()
        probe.copy("private notes")
        let session = DictationSession(trigger: .menu, mode: mode, source: .live)

        await ContextCaptureParticipant(services: services).willStart(session)

        XCTAssertFalse(try XCTUnwrap(session.prompt).system.contains("private notes"))
        XCTAssertNil(services.live.clipboardChip)
        XCTAssertEqual(probe.stringReads, 0, "the clipboard is not even read")
    }

    func testVoiceModeRendersNothing() async throws {
        let voice = try XCTUnwrap(manager.mode(forKey: "voice"))
        probe.copy("copied")
        let session = DictationSession(trigger: .menu, mode: voice, source: .live)

        await ContextCaptureParticipant(services: services).willStart(session)

        XCTAssertNil(session.prompt)
        XCTAssertNil(services.live.clipboardChip)
        XCTAssertTrue(refiner.warmed.isEmpty)
    }

    func testRefinementOffRendersNothingUnlessTheModeHasAModel() async throws {
        settings.refinement.refinementEnabled = false
        var mode = try clipboardMode()
        let off = DictationSession(trigger: .menu, mode: mode, source: .live)
        await ContextCaptureParticipant(services: services).willStart(off)
        XCTAssertNil(off.prompt)

        mode.languageModelID = "localServer/test-model"
        let opted = DictationSession(trigger: .menu, mode: mode, source: .live)
        await ContextCaptureParticipant(services: services).willStart(opted)
        XCTAssertNotNil(opted.prompt)
        XCTAssertEqual(refiner.warmed, ["localServer/test-model"])
    }

    func testCancelClearsChipsAndActivation() async throws {
        let mode = try clipboardMode()
        probe.copy("copied")
        let session = DictationSession(trigger: .menu, mode: mode, source: .live)
        let participant = ContextCaptureParticipant(services: services)
        await participant.willStart(session)

        participant.didCancel(session)

        XCTAssertNil(services.live.clipboardChip)
        XCTAssertEqual(manager.activeModeKey, "super")
    }
}
