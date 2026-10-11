import XCTest

@testable import Parrot

/// Picking a mode while recording moves the recording in progress to that
/// mode, and RefineStage renders the prompt again for it. Fake microphone,
/// fake clipboard probe, fake refiner; no voice model and no network.
@MainActor
final class ModeSwitchTests: XCTestCase {

    private final class SilentMicrophone: AudioCapturing {
        var didReachCapacity = false
        func startRecording() throws {}
        func stopRecording() -> [Float] { Array(repeating: 0.1, count: 16_000) }
    }

    private final class RecordingRefiner: Refiner {
        private(set) var requests: [RefinementRequest] = []
        func refine(_ text: String, modePrompt: String?, context: DictationContext?, settings: AppSettings) async throws -> String { text }
        func warmUpIfLocal(settings: AppSettings) {}
        func refine(_ request: RefinementRequest, settings: AppSettings) async throws -> String {
            requests.append(request)
            return request.user
        }
        func warmUp(languageModelID: String, settings: AppSettings) {}
    }

    /// Stands in for transcription: the recording "said" this.
    private final class FixedTranscriptStage: DictationStage {
        var failurePolicy: StageFailurePolicy { .abort }
        var runsAfterFinish: Bool { false }
        init(services: AppServices) {}
        func run(_ session: DictationSession) async throws -> StageResult {
            session.rawTranscript = "hello there"
            session.text = "hello there"
            return .continue
        }
    }

    private var root: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    private var services: AppServices!
    private var refiner: RecordingRefiner!
    private var manager: ModeManager!
    private var first: Mode!
    private var second: Mode!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-modeswitch-\(UUID().uuidString)", isDirectory: true)
        suiteName = "parrot.tests.modeswitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        settings.refinement.refinementEnabled = true

        services = AppServices(vocabulary: VocabularyManager(storageURL: root.appendingPathComponent("vocabulary.json")))
        services.settings = settings
        services.showTransientError = { message in XCTFail("unexpected toast: \(message)") }
        services.context = ContextService(clipboard: ClipboardWatcher(probe: FakeClipboardProbe()))
        refiner = RecordingRefiner()
        services.refiner = refiner

        let paths = AppPaths(root: root)
        manager = ModeManager(modesDirectory: paths.modes, legacyFileURL: paths.legacyModesFile, defaults: defaults, seedsPresets: false)
        first = manager.addMode(Mode(name: "Formal", refinementPrompt: "FIRST-MODE INSTRUCTIONS"))
        second = manager.addMode(Mode(name: "Pirate", refinementPrompt: "SECOND-MODE INSTRUCTIONS"))
        manager.selectMode(first)
        services.modes = manager
    }

    override func tearDown() {
        services = nil
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func controller(stages: [any DictationStage] = [], participants: [any RecordingParticipant] = []) -> DictationController {
        let microphone = SilentMicrophone()
        return DictationController(
            services: services,
            pipeline: DictationPipeline(stages: stages, participants: participants),
            recorder: { microphone }
        )
    }

    // MARK: - Controller

    func testSwitchWhileRecordingChangesTheSessionMode() async throws {
        let controller = controller()
        await controller.start(trigger: .menu, modeOverride: first)?.value
        let session = try XCTUnwrap(controller.session)
        XCTAssertEqual(services.live.modeName, "Formal")

        controller.switchMode(to: second)

        XCTAssertEqual(session.mode?.id, second.id)
        XCTAssertEqual(services.live.modeName, "Pirate")
        await controller.stop(trigger: .menu)?.value
        XCTAssertEqual(session.mode?.id, second.id)
    }

    func testSwitchWhileIdleIsIgnored() {
        let controller = controller()
        controller.switchMode(to: second)
        XCTAssertNil(controller.session)
        XCTAssertNil(services.live.modeName)
    }

    func testSwitchAfterTheMicClosesIsIgnored() async throws {
        let controller = controller()
        await controller.start(trigger: .menu, modeOverride: first)?.value
        let session = try XCTUnwrap(controller.session)
        let processing = controller.stop(trigger: .menu)
        XCTAssertEqual(controller.phase, .processing)

        controller.switchMode(to: second)

        XCTAssertEqual(session.mode?.id, first.id)
        await processing?.value
    }

    func testModeSwitcherPickMovesTheRecording() async throws {
        let controller = controller()
        services.hotkeys.install(controller: controller)
        await controller.start(trigger: .pushToTalk, modeOverride: first)?.value
        let session = try XCTUnwrap(controller.session)

        services.hotkeys.select(second)

        XCTAssertEqual(manager.selectedMode.id, second.id)
        XCTAssertEqual(session.mode?.id, second.id)
        controller.cancel()
    }

    // MARK: - Prompt

    /// The real start render, a pick in the switcher, then RefineStage: the
    /// language model gets the new mode's instructions.
    func testPromptIsRenderedAgainForTheModePickedMidRecording() async throws {
        let controller = controller(
            stages: [FixedTranscriptStage(services: services), RefineStage(services: services)],
            participants: [ContextCaptureParticipant(services: services)]
        )
        services.hotkeys.install(controller: controller)
        await controller.start(trigger: .pushToTalk)?.value
        let session = try XCTUnwrap(controller.session)
        XCTAssertEqual(session.mode?.id, first.id, "the selected mode at start")
        let startPrompt = try XCTUnwrap(session.prompt)
        XCTAssertTrue(startPrompt.system.contains("FIRST-MODE INSTRUCTIONS"))
        XCTAssertEqual(session.promptMode?.id, first.id)

        services.hotkeys.select(second)
        await controller.stop(trigger: .pushToTalk)?.value

        let request = try XCTUnwrap(refiner.requests.first)
        XCTAssertTrue(request.system.contains("SECOND-MODE INSTRUCTIONS"), request.system)
        XCTAssertFalse(request.system.contains("FIRST-MODE INSTRUCTIONS"))
        XCTAssertEqual(request.user, "hello there")
        XCTAssertEqual(session.promptMode?.id, second.id)
        XCTAssertTrue(session.renderedPrompt?.contains("SECOND-MODE INSTRUCTIONS") == true)
    }

    func testStartPromptIsKeptWhenTheModeIsUnchanged() async throws {
        let session = DictationSession(trigger: .pushToTalk, mode: first, source: .live)
        session.context = DictationContext()
        session.prompt = RenderedPrompt(system: "RENDERED AT START", user: RenderedPrompt.transcriptPlaceholder)
        session.promptMode = first
        session.text = "hello there"

        _ = try await RefineStage(services: services).run(session)

        XCTAssertEqual(refiner.requests.first?.system, "RENDERED AT START")
        XCTAssertEqual(refiner.requests.first?.user, "hello there")
    }

    func testChangedModeRendersAgainInRefineStage() async throws {
        let session = DictationSession(trigger: .pushToTalk, mode: first, source: .live)
        session.context = DictationContext()
        session.prompt = RenderedPrompt(system: "RENDERED AT START", user: RenderedPrompt.transcriptPlaceholder)
        session.promptMode = first
        session.mode = second
        session.text = "hello there"

        _ = try await RefineStage(services: services).run(session)

        let system = try XCTUnwrap(refiner.requests.first?.system)
        XCTAssertNotEqual(system, "RENDERED AT START")
        XCTAssertTrue(system.contains("SECOND-MODE INSTRUCTIONS"), system)
    }
}
