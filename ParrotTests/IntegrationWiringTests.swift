import XCTest

@testable import Parrot

/// Wiring left open by the workstreams: the lid-closed modal after a
/// recording, the Modes and Vocabulary first-run tips, and the most used
/// mode tile. Fake audio hardware and a fake presenter; no window opens.
@MainActor
final class IntegrationWiringTests: XCTestCase {

    private let builtIn = AudioDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioDevice(id: 20, uid: "usb-mic", name: "USB Mic")

    private var suiteName = ""
    private var settings: AppSettings!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "parrot.tests.wiring.\(UUID().uuidString)"
        settings = AppSettings(store: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!), secrets: InMemorySecretStore())
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Lid Closed

    private func lidServices() -> (AppServices, FakeAudioHardware, FakeRecorderPresenter) {
        let services = AppServices(vocabulary: VocabularyManager(
            storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("parrot-wiring-\(UUID().uuidString).json")
        ))
        services.settings = settings
        let hardware = FakeAudioHardware(devices: [builtIn], defaultID: 10)
        services.devices = AudioDeviceService(hardware: hardware)
        services.devices.attach(settings: settings.audio, recorder: nil, live: services.live)
        let presenter = FakeRecorderPresenter()
        services.recorderUI = presenter
        return (services, hardware, presenter)
    }

    private func finish(_ participant: RecorderUIParticipant, source: DictationSource = .live, cancelled: Bool = false) {
        let session = DictationSession(trigger: .pushToTalk, source: source)
        if cancelled {
            session.isCancelled = true
            participant.didCancel(session)
        } else {
            session.outcome = .empty
            participant.didFinish(session)
        }
    }

    func testLidModalShowsOncePerEpisodeAfterARecording() {
        let (services, hardware, presenter) = lidServices()
        let participant = RecorderUIParticipant(services: services)

        finish(participant)
        XCTAssertFalse(presenter.events.contains("lid"), "lid open: no modal")

        services.devices.lidStateChanged(true)
        XCTAssertNotNil(services.live.lidWarning)
        XCTAssertFalse(presenter.events.contains("lid"), "never on lid close itself, only after a recording")

        finish(participant)
        XCTAssertEqual(presenter.events.filter { $0 == "lid" }.count, 1)
        finish(participant, cancelled: true)
        XCTAssertEqual(presenter.events.filter { $0 == "lid" }.count, 1, "once per episode")

        // An external mic fixes it; then it is unplugged: a new episode.
        hardware.devices = [builtIn, usb]
        services.devices.hardwareChanged(.devices)
        XCTAssertNil(services.live.lidWarning)
        finish(participant)
        XCTAssertEqual(presenter.events.filter { $0 == "lid" }.count, 1)

        hardware.devices = [builtIn]
        services.devices.hardwareChanged(.devices)
        XCTAssertNotNil(services.live.lidWarning)
        finish(participant, cancelled: true)
        XCTAssertEqual(presenter.events.filter { $0 == "lid" }.count, 2, "a cancelled recording warns too")
    }

    func testLidModalSkipsFileRuns() {
        let (services, _, presenter) = lidServices()
        let participant = RecorderUIParticipant(services: services)
        services.devices.lidStateChanged(true)

        finish(participant, source: .file(URL(fileURLWithPath: "/tmp/parrot-wiring.wav")))

        XCTAssertFalse(presenter.events.contains("lid"))
    }

    // MARK: - First-Run Tips

    func testModesTipsFollowWhatTheUserDid() {
        let presets = ModePresets.defaultModes
        XCTAssertEqual(FirstRunToasts.satisfied(modes: presets), [])

        var own = Mode(key: "standup", name: "Standup notes")
        XCTAssertEqual(FirstRunToasts.satisfied(modes: presets + [own]), ["modes.create"])

        own.activationSites = ["github.com"]
        var shortcut = presets[2]
        shortcut.shortcut = ModeShortcut(keyCode: 18, modifiers: 0, mouseButton: nil)
        XCTAssertEqual(
            FirstRunToasts.satisfied(modes: [presets[0], shortcut, own]),
            ["modes.create", "modes.activation", "modes.shortcut"]
        )

        var app = presets[3]
        app.appBundleIDs = ["com.apple.mail"]
        XCTAssertEqual(FirstRunToasts.satisfied(modes: presets.dropLast() + [app]), ["modes.activation"])
        XCTAssertEqual(
            FirstRunToasts.visible(on: .modes, dismissed: [], satisfied: FirstRunToasts.satisfied(modes: [app])).map(\.id),
            ["modes.create", "modes.shortcut"]
        )
    }

    func testVocabularyTipsFollowWhatTheUserDid() {
        XCTAssertEqual(FirstRunToasts.satisfied(vocabulary: []), [])
        XCTAssertEqual(FirstRunToasts.satisfied(vocabulary: [.word("Parrot")]), ["vocabulary.firstItem"])
        let replacement = VocabularyEntry(original: "my address", replacement: "1 Main Street")
        XCTAssertEqual(FirstRunToasts.satisfied(vocabulary: [replacement]), ["vocabulary.firstReplacement"])
        XCTAssertEqual(
            FirstRunToasts.visible(on: .vocabulary, dismissed: [], satisfied: FirstRunToasts.satisfied(vocabulary: [.word("Parrot"), replacement])),
            []
        )
    }

    // MARK: - Stats Tiles

    func testMostUsedModeTileText() {
        XCTAssertEqual(StatsMath.modeText(nil), "None")
        XCTAssertEqual(StatsMath.modeText("  "), "None")
        XCTAssertEqual(StatsMath.modeText("Email"), "Email")
    }
}
