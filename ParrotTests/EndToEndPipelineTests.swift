import XCTest

@testable import Parrot

/// Stands in for the microphone: opening it does nothing, and closing it
/// hands back the samples the test "spoke". The test feeds the same samples
/// through a real (never started) `AudioRecorder` while recording, so the
/// WAV writer and level meter get every frame as they would from the tap.
private final class FixtureMicrophone: AudioCapturing {
    let samples: [Float]
    var didReachCapacity = false

    init(samples: [Float]) {
        self.samples = samples
    }

    func startRecording() throws {}

    func stopRecording() -> [Float] { samples }
}

/// Returns the user message in capitals, so the test can see refinement
/// output reach the clipboard. Never touches the network.
private final class UppercaseRefiner: Refiner {
    private(set) var requests: [RefinementRequest] = []

    func refine(_ text: String, modePrompt: String?, context: DictationContext?, settings: AppSettings) async throws -> String {
        text.uppercased()
    }

    func warmUpIfLocal(settings: AppSettings) {}

    func refine(_ request: RefinementRequest, settings: AppSettings) async throws -> String {
        requests.append(request)
        return request.user.uppercased()
    }

    func warmUp(languageModelID: String, settings: AppSettings) {}
}

/// The whole dictation, start to saved, as one piece: the real controller,
/// every participant and stage from `PipelineOrder`, the cached voice
/// models, a temporary history database and recordings folder.
///
/// Nothing reaches outside the test process: auto-paste is off (checked
/// before every run, so no keystroke is ever posted), the clipboard is a
/// fake, sound cues and playback control are off, toasts are captured, and
/// the microphone is a fake. The participants still read the frontmost app
/// and focused field through Accessibility (read only); if a secure field
/// happens to have focus on the Mac, history is skipped by design and the
/// history assertions here fail.
@MainActor
final class EndToEndPipelineTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    private var services: AppServices!
    private var pasteboard: FakePasteboard!
    /// Never started: it only fans the fixture frames out to the sinks.
    private var frameSource: AudioRecorder!
    private var toasts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "parrot.tests.e2e.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        settings.output.autoPaste = false
        settings.audio.soundEffectsEnabled = false
        settings.audio.playbackBehavior = .keepPlaying
        settings.transcription.silenceRemoval = true
        settings.refinement.refinementEnabled = false
        settings.vocabulary.vocabularyBoostingEnabled = false
        settings.history.historyEnabled = true

        let paths = AppPaths(root: root)
        let vocabulary = VocabularyManager(storageURL: root.appendingPathComponent("vocabulary.json"))
        vocabulary.addEntry(original: "test", replacement: "check")

        services = AppServices(vocabulary: vocabulary)
        services.paths = paths
        services.settings = settings
        services.showTransientError = { [weak self] message in self?.toasts.append(message) }
        services.history = try HistoryStore(databaseURL: paths.historyDatabase, recordingsRoot: paths.recordings)
        services.modes = ModeManager(
            modesDirectory: paths.modes, legacyFileURL: paths.legacyModesFile, defaults: defaults, seedsPresets: false
        )
        pasteboard = FakePasteboard()
        services.output.clipboard = ClipboardService(pasteboard: pasteboard, scheduler: ManualScheduler())
        frameSource = AudioRecorder()
        services.audioRecorder = frameSource
        toasts = []
    }

    override func tearDown() async throws {
        services = nil
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Cases

    /// Default mode, global Parakeet V3, silence removal, one replacement.
    func testParakeetDictationIsCopiedAndSaved() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let samples = try ASRFixture.padded(seconds: 1)

        let session = try await dictate(samples)

        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(session.mode?.name, "Default")
        XCTAssertEqual(session.voiceModelID, VoiceModels.parakeetV3.id)
        XCTAssertNotNil(session.speechSeconds, "silence removal did not run")
        let trimmed = try XCTUnwrap(session.transcriptionAudio, "no silence was removed")
        XCTAssertLessThan(trimmed.count, samples.count - 16_000, "expected over 1 s of the 2 s padding cut")
        XCTAssertEqual(session.samples.count, samples.count, "the recording itself stays whole")
        assertDelivered(session, raw: "test", final: "check")
        try assertSaved(session, sampleCount: samples.count)
        report("parakeet", session)
    }

    /// A mode whose voice model is Whisper tiny, picked as the selected
    /// mode so ContextCaptureParticipant resolves it.
    func testWhisperModeDictationUsesTheModesVoiceModel() async throws {
        try XCTSkipUnless(WhisperKitEngine.isDownloaded(variant: "openai_whisper-tiny"), "Whisper tiny not cached")
        let modes = try XCTUnwrap(services.modes)
        let whisper = modes.addMode(Mode(name: "Whisper", voiceModelID: "whisper-tiny"))
        modes.selectMode(whisper)
        let samples = try ASRFixture.padded(seconds: 1)

        let session = try await dictate(samples)

        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(session.mode?.name, "Whisper")
        XCTAssertEqual(session.voiceModelID, "whisper-tiny")
        assertDelivered(session, raw: "test", final: "check")
        try assertSaved(session, sampleCount: samples.count)
        XCTAssertEqual(try services.history?.entries().first?.modeName, "Whisper")
        report("whisper-tiny", session)
    }

    /// Refinement on with a fake language model: its output is what lands
    /// on the clipboard and in history.
    func testRefinedTextReachesTheClipboard() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let refiner = UppercaseRefiner()
        services.refiner = refiner
        settings.refinement.refinementEnabled = true
        let samples = try ASRFixture.padded(seconds: 1)

        let session = try await dictate(samples)

        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(refiner.requests.count, 1)
        let request = try XCTUnwrap(refiner.requests.first)
        XCTAssertTrue(request.user.lowercased().contains("check"), "the refiner gets the replaced transcript: \(request.user)")
        XCTAssertNotNil(session.renderedPrompt)
        let llmText = try XCTUnwrap(session.llmText)
        XCTAssertEqual(llmText, llmText.uppercased())

        let clipboard = try XCTUnwrap(pasteboard.text)
        XCTAssertEqual(clipboard, session.text)
        XCTAssertTrue(clipboard.contains("HELLO"), "unexpected clipboard: \(clipboard)")
        XCTAssertTrue(clipboard.contains("CHECK"), "unexpected clipboard: \(clipboard)")
        XCTAssertEqual(clipboard, clipboard.uppercased())
        XCTAssertTrue(toasts.isEmpty, "unexpected toasts: \(toasts)")

        let entry = try XCTUnwrap(try services.history?.entries().first)
        XCTAssertEqual(entry.finalText, clipboard)
        XCTAssertEqual(entry.llmText, llmText)
        XCTAssertEqual(entry.rawTranscript, session.rawTranscript)
        report("refined", session)
    }

    // MARK: - Helpers

    private struct UnsafeDelivery: Error {}

    /// Records `samples` through the real controller and pipeline, as a
    /// push-to-talk press and release would.
    private func dictate(_ samples: [Float], mode: Mode? = nil) async throws -> DictationSession {
        // The Mac test process is Accessibility-trusted: stop here unless
        // delivery can only copy, whatever the trust or Shift state.
        let policy = DeliveryPolicy(
            settings: settings.output, mode: mode ?? services.modes?.selectedMode,
            shiftHeldAtStop: true, accessibilityTrusted: true
        )
        guard policy.method == .clipboardOnly(.autoPasteOff), !policy.pressReturn else {
            XCTFail("delivery would paste or type: \(policy)")
            throw UnsafeDelivery()
        }

        // Silence removal skips itself until Silero VAD is loaded.
        try await services.vad.prepare()
        let microphone = FixtureMicrophone(samples: samples)
        let controller = DictationController(services: services, recorder: { microphone })

        let opening = controller.start(trigger: .pushToTalk, modeOverride: mode)
        let session = try XCTUnwrap(controller.session, "start was ignored")
        await opening?.value
        XCTAssertEqual(controller.phase, .recording)

        AudioFixture.feed(samples, to: frameSource)
        let processing = try XCTUnwrap(controller.stop(trigger: .pushToTalk), "stop was ignored or discarded")
        await processing.value
        XCTAssertEqual(controller.phase, .idle)
        return session
    }

    /// The clipboard holds the final text, with the replacement applied.
    private func assertDelivered(_ session: DictationSession, raw: String, final: String, file: StaticString = #filePath, line: UInt = #line) {
        let rawText = session.rawTranscript.lowercased()
        XCTAssertTrue(rawText.contains("hello"), "unexpected transcript: \(session.rawTranscript)", file: file, line: line)
        XCTAssertTrue(Self.words(rawText).contains(raw), "the recognizer should hear '\(raw)': \(session.rawTranscript)", file: file, line: line)

        guard let clipboard = pasteboard.text else {
            XCTFail("nothing on the clipboard", file: file, line: line)
            return
        }
        XCTAssertEqual(clipboard, session.text, file: file, line: line)
        let words = Self.words(clipboard.lowercased())
        XCTAssertTrue(words.contains("hello"), "unexpected clipboard: \(clipboard)", file: file, line: line)
        XCTAssertTrue(words.contains(final), "replacement missing: \(clipboard)", file: file, line: line)
        XCTAssertFalse(words.contains(raw), "replacement not applied: \(clipboard)", file: file, line: line)
        XCTAssertTrue(pasteboard.types.contains(PasteboardMarker.transient), "clipboard history is off by default", file: file, line: line)
        XCTAssertTrue(toasts.isEmpty, "unexpected toasts: \(toasts)", file: file, line: line)
    }

    /// One history row with raw and final text, and the recording folder
    /// with `output.wav` and `meta.json`.
    private func assertSaved(_ session: DictationSession, sampleCount: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let history = try XCTUnwrap(services.history, file: file, line: line)
        XCTAssertEqual(try history.count(), 1, file: file, line: line)
        let entry = try XCTUnwrap(try history.entries().first, file: file, line: line)
        XCTAssertEqual(entry.rawTranscript, session.rawTranscript, file: file, line: line)
        XCTAssertEqual(entry.finalText, session.text, file: file, line: line)
        XCTAssertEqual(entry.modeName, session.mode?.name, file: file, line: line)

        let folder = try XCTUnwrap(session.recordingFolder, "no recording folder", file: file, line: line)
        XCTAssertEqual(
            folder.deletingLastPathComponent().standardizedFileURL, services.paths.recordings.standardizedFileURL,
            file: file, line: line
        )
        let wav = services.paths.recordingAudio(in: folder)
        XCTAssertEqual(try AudioFixture.decode(wav).count, sampleCount, "output.wav holds every frame", file: file, line: line)
        XCTAssertEqual(entry.audioPath, wav.path, file: file, line: line)
        XCTAssertEqual(entry.folderPath.map { URL(fileURLWithPath: $0).standardizedFileURL }, folder.standardizedFileURL, file: file, line: line)

        let meta = try XCTUnwrap(try RecordingMeta.read(from: folder), "meta.json missing", file: file, line: line)
        XCTAssertEqual(meta.finalText, session.text, file: file, line: line)
        XCTAssertEqual(meta.rawText, session.rawTranscript, file: file, line: line)
        XCTAssertEqual(meta.outcome, "copiedOnly", file: file, line: line)
        XCTAssertEqual(meta.trigger, RecordingTrigger.pushToTalk.rawValue, file: file, line: line)
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// One line per run for the report: transcript, final text, timings.
    private func report(_ label: String, _ session: DictationSession) {
        let timings = session.timings.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
            .joined(separator: " ")
        print("[E2E] \(label) raw=\"\(session.rawTranscript)\" final=\"\(session.text)\" speech=\(String(format: "%.2f", session.speechSeconds ?? 0))s of \(String(format: "%.2f", session.duration))s timings: \(timings)")
    }
}
