import XCTest

@testable import Parrot

/// A fake on-device engine: counts lifecycle calls, optional slow load,
/// fails a transcription when not loaded.
private actor FakeEngine: BatchTranscriptionEngine {
    var downloaded = true
    var loadDelay: TimeInterval = 0
    private(set) var loaded = false
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var transcribeCount = 0
    private(set) var vocabularyCalls = 0

    func setLoadDelay(_ seconds: TimeInterval) { loadDelay = seconds }
    func setDownloaded(_ value: Bool) { downloaded = value }
    /// Drops the model behind the router's back.
    func forget() { loaded = false }

    func isDownloaded() async -> Bool { downloaded }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
        downloaded = true
    }

    func load() async throws {
        loadCount += 1
        if loadDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(loadDelay * 1_000_000_000))
        }
        loaded = true
    }

    func unload() async {
        unloadCount += 1
        loaded = false
    }

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        guard loaded else { throw TranscriptionFailure.engineNotReady }
        transcribeCount += 1
        return TranscriptOutput(text: "fake \(samples.count)", language: options.language)
    }

    func applyVocabulary(_ entries: [VocabularyEntry], enabled: Bool) async {
        vocabularyCalls += 1
    }
}

/// Per-mode routing, single-flight loads, the load timeout, keep-alive
/// unloads, and the mode editor rules, all with fake engines.
@MainActor
final class RouterTests: XCTestCase {

    private var env: ASRTestEnvironment!
    private var engines: [String: FakeEngine] = [:]

    override func setUp() async throws {
        env = ASRTestEnvironment()
        engines = [:]
    }

    override func tearDown() async throws {
        env.tearDown()
        env = nil
    }

    private func makeRouter(loadTimeout: TimeInterval = 5, keepAlive: TimeInterval? = 0) -> TranscriptionRouter {
        let router = TranscriptionRouter(
            vocabulary: env.services.vocabulary, loadTimeout: loadTimeout
        ) { [unowned self] model, _ in
            if let engine = self.engines[model.id] { return engine }
            let engine = FakeEngine()
            self.engines[model.id] = engine
            return engine
        }
        router.keepAliveOverride = keepAlive
        return router
    }

    private let model = VoiceModels.parakeetV2

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Routing

    func testModeModelWinsOverTheGlobalProvider() {
        let router = makeRouter()
        env.settings.transcription.transcriptionProvider = .openAI

        XCTAssertEqual(router.resolveModel(for: Mode(name: "M", voiceModelID: "whisper-tiny"), settings: env.settings).id, "whisper-tiny")
        XCTAssertEqual(router.resolveModel(for: Mode(name: "M"), settings: env.settings).id, "cloud-openai")
        XCTAssertEqual(router.resolveModel(for: nil, settings: env.settings).id, "cloud-openai")
        XCTAssertEqual(
            router.resolveModel(for: Mode(name: "M", voiceModelID: "no-such-model"), settings: env.settings).id,
            "cloud-openai", "an unknown id falls back to the global provider"
        )

        env.settings.transcription.transcriptionProvider = .parakeet
        XCTAssertEqual(router.resolveModel(for: Mode(name: "M"), settings: env.settings).id, "parakeet-v3")
    }

    func testProductionRouterBuildsTheRightEngines() throws {
        let router = TranscriptionRouter(vocabulary: env.services.vocabulary)
        XCTAssertTrue(try router.engine(for: VoiceModels.parakeetV3, settings: env.settings) is TranscriptionEngine)
        XCTAssertTrue(router.engine === (try router.engine(for: VoiceModels.parakeetV3, settings: env.settings) as AnyObject))
        XCTAssertTrue(try router.engine(for: VoiceModels.parakeetV2, settings: env.settings) is TranscriptionEngine)
        let whisper = try XCTUnwrap(VoiceModels.model(id: "whisper-tiny"))
        XCTAssertTrue(try router.engine(for: whisper, settings: env.settings) is WhisperKitEngine)

        XCTAssertThrowsError(try router.engine(for: VoiceModels.cloudOpenAI, settings: env.settings)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .notConfigured("OpenAI (cloud)"))
        }
        env.settings.credentials.setKey("sk-test-placeholder", for: .openAI)
        XCTAssertTrue(try router.engine(for: VoiceModels.cloudOpenAI, settings: env.settings) is CloudBatchEngine)
    }

    // MARK: - Loading

    func testConcurrentLoadsRunOnce() async throws {
        let router = makeRouter()
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)
        await engine.setLoadDelay(0.3)

        async let a = router.ensureLoaded(model, settings: env.settings)
        async let b = router.ensureLoaded(model, settings: env.settings)
        async let c = router.ensureLoaded(model, settings: env.settings)
        _ = try await (a, b, c)

        let loads = await engine.loadCount
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(router.isResident(model))
    }

    func testLoadTimeoutEndsTheWait() async throws {
        let router = makeRouter(loadTimeout: 0.2)
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)
        await engine.setLoadDelay(2)

        let started = Date()
        do {
            _ = try await router.ensureLoaded(model, settings: env.settings)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .loadTimedOut(model.name, 0.2))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertFalse(router.isResident(model))
    }

    func testNotDownloadedModelIsNotFetchedDuringDictation() async throws {
        let router = makeRouter()
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)
        await engine.setDownloaded(false)

        do {
            _ = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
            XCTFail("expected modelNotDownloaded")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .modelNotDownloaded(model.name))
        }

        try await router.download(model, settings: env.settings)
        let output = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
        XCTAssertEqual(output.text, "fake 1")
    }

    func testEngineThatLostItsModelIsReloadedAndRetriedOnce() async throws {
        let router = makeRouter()
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)
        _ = try await router.ensureLoaded(model, settings: env.settings)
        await engine.forget()

        let output = try await router.transcribe([0, 0], model: model, options: TranscriptionOptions(), settings: env.settings)

        XCTAssertEqual(output.text, "fake 2")
        let loads = await engine.loadCount
        XCTAssertEqual(loads, 2)
    }

    // MARK: - Keep-Alive

    func testIdleModelUnloadsAfterTheKeepAliveAndReloadsOnUse() async throws {
        let router = makeRouter(keepAlive: 0.15)
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)

        _ = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
        XCTAssertTrue(router.isResident(model))

        try await sleep(0.5)
        XCTAssertFalse(router.isResident(model))
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 1)

        _ = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
        let loads = await engine.loadCount
        XCTAssertEqual(loads, 2)
    }

    func testRetainedModelStaysLoadedUntilReleased() async throws {
        let router = makeRouter(keepAlive: 0.15)
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)

        router.retain(model)
        _ = try await router.ensureLoaded(model, settings: env.settings)
        try await sleep(0.4)
        XCTAssertTrue(router.isResident(model), "a recording in progress keeps its model")

        router.release(model)
        try await sleep(0.4)
        XCTAssertFalse(router.isResident(model))
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 1)
    }

    func testKeepAliveReadsTheSetting() async throws {
        let router = makeRouter(keepAlive: nil)
        env.settings.transcription.activeDuration = 0.15
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)

        _ = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
        try await sleep(0.5)

        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 1)
    }

    func testZeroKeepAliveNeverUnloads() async throws {
        let router = makeRouter(keepAlive: 0)
        _ = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
        try await sleep(0.3)
        XCTAssertTrue(router.isResident(model))
    }

    func testVocabularyIsAppliedOnLoadAndUse() async throws {
        let router = makeRouter()
        let engine = try XCTUnwrap(try router.engine(for: model, settings: env.settings) as? FakeEngine)
        _ = try await router.transcribe([0], model: model, options: TranscriptionOptions(), settings: env.settings)
        let calls = await engine.vocabularyCalls
        XCTAssertEqual(calls, 2, "once after load, once before the run")
    }

    // MARK: - Options, Languages, Mode Rules

    func testOptionsFromMode() {
        XCTAssertNil(TranscriptionOptions(mode: Mode(name: "M")).language)
        let fixed = TranscriptionOptions(mode: Mode(name: "M", language: "de", translateToEnglish: true))
        XCTAssertEqual(fixed.language, "de")
        XCTAssertTrue(fixed.translateToEnglish)
    }

    func testLanguageLists() throws {
        XCTAssertEqual(LanguageCatalog.languages(for: VoiceModels.parakeetV3).count, 25)
        XCTAssertGreaterThanOrEqual(LanguageCatalog.languages(for: try XCTUnwrap(VoiceModels.model(id: "whisper-base"))).count, 99)
        XCTAssertEqual(LanguageCatalog.choices(for: VoiceModels.parakeetV3).first?.code, "auto")
        XCTAssertEqual(LanguageCatalog.choices(for: VoiceModels.parakeetV2).map(\.code), ["en"])
        XCTAssertEqual(LanguageCatalog.choices(for: try XCTUnwrap(VoiceModels.model(id: "whisper-tiny.en"))).map(\.code), ["en"])
        XCTAssertEqual(Set(VoiceModels.all.map(\.id)).count, VoiceModels.all.count, "ids are unique")
    }

    func testRealtimeAndSpeakersExcludeEachOtherForAModel() {
        var mode = Mode(name: "M", voiceModelID: "parakeet-v3")
        XCTAssertTrue(VoiceModeRules(model: VoiceModels.parakeetV3, mode: mode).canEnableRealtime)
        XCTAssertTrue(VoiceModeRules(model: VoiceModels.parakeetV3, mode: mode).canEnableDiarize)

        mode.diarize = true
        let withSpeakers = VoiceModeRules(model: VoiceModels.parakeetV3, mode: mode)
        XCTAssertFalse(withSpeakers.canEnableRealtime)
        XCTAssertNotNil(withSpeakers.realtimeBlockedReason)

        mode.diarize = false
        mode.realtimeOutput = true
        let withLive = VoiceModeRules(model: VoiceModels.parakeetV3, mode: mode)
        XCTAssertFalse(withLive.canEnableDiarize)
        XCTAssertNotNil(withLive.diarizeBlockedReason)
    }

    func testPickingAModelResetsWhatItCannotDo() throws {
        let whisper = try XCTUnwrap(VoiceModels.model(id: "whisper-small"))
        let mode = Mode(name: "M", voiceModelID: "whisper-small", language: "ja", translateToEnglish: true, realtimeOutput: false)
        let onParakeet = VoiceModeRules.adjusted(mode, for: VoiceModels.parakeetV3)
        XCTAssertEqual(onParakeet.language, "auto", "Japanese is not a Parakeet V3 language")
        XCTAssertFalse(onParakeet.translateToEnglish)

        let live = Mode(name: "M", realtimeOutput: true)
        XCTAssertFalse(VoiceModeRules.adjusted(live, for: whisper).realtimeOutput)
        XCTAssertEqual(VoiceModeRules.adjusted(Mode(name: "M", language: "fr"), for: VoiceModels.parakeetV2).language, "en")
    }
}
