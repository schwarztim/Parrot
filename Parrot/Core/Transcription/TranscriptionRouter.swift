import Foundation

/// Progress of the one-time model download, load and prewarm.
enum ModelPreparationEvent {
    case progress(Double)
    case ready
    case failed(Error)
}

/// Picks the voice model for each dictation and owns every engine's
/// lifecycle. [ASR]
///
/// - Routing: a mode's `voiceModelID` names a model in `VoiceModels`; an
///   empty or unknown id falls back to the global provider setting.
/// - Downloads run once per model (single flight) with no time limit.
/// - Loads run once per model (single flight); a waiter gives up after
///   `loadTimeout` (120 s) while the load itself carries on.
/// - Keep-alive: an on-device model unloads after the active duration
///   setting passes with no use. The next use loads it again.
@MainActor
final class TranscriptionRouter {

    /// Makes the engine for a model. Tests pass fakes.
    typealias EngineFactory = @MainActor (VoiceModelInfo, AppSettings?) throws -> any BatchTranscriptionEngine

    // MARK: - Compatibility

    /// The Parakeet V3 engine, created by the first `prepare` call or
    /// the first V3 dictation.
    private(set) var engine: TranscriptionEngine?

    /// True once Parakeet V3 has been downloaded and loaded once. Stays
    /// true when the keep-alive unloads it: the next use reloads it.
    private(set) var isModelReady = false

    /// Guards `prepare` against launching more than one preparation.
    private var preparationStarted = false

    // MARK: - State

    private let vocabulary: VocabularyManager
    private let factory: EngineFactory?
    let loadTimeout: TimeInterval
    /// Seconds a model stays loaded after its last use. Nil reads the
    /// active duration setting.
    var keepAliveOverride: TimeInterval?

    /// The settings from the last call that passed them.
    private weak var settings: AppSettings?

    private var engines: [String: any BatchTranscriptionEngine] = [:]
    private var resident: Set<String> = []
    private var downloads: [String: Task<Void, Error>] = [:]
    private var loads: [String: Task<Void, Error>] = [:]
    private var useCounts: [String: Int] = [:]
    private var unloadTimers: [String: Task<Void, Never>] = [:]

    init(vocabulary: VocabularyManager) {
        self.vocabulary = vocabulary
        self.factory = nil
        self.loadTimeout = 120
    }

    /// For tests: fake engines and a short load timeout.
    init(vocabulary: VocabularyManager, loadTimeout: TimeInterval, factory: @escaping EngineFactory) {
        self.vocabulary = vocabulary
        self.factory = factory
        self.loadTimeout = loadTimeout
    }

    /// Transcribes an audio file opened with Parrot (Open With, a file
    /// URL). Stub: ignored until file transcription lands.
    func openFile(_ url: URL) {}

    // MARK: - Routing

    /// The model a dictation in `mode` uses.
    func resolveModel(for mode: Mode?, settings: AppSettings?) -> VoiceModelInfo {
        let id = mode?.voiceModelID.trimmingCharacters(in: .whitespaces) ?? ""
        if !id.isEmpty {
            if let model = VoiceModels.model(id: id) { return model }
            diagLog("[Parrot:Router] Unknown voice model '\(id)', using the global provider")
        }
        return VoiceModels.model(for: settings?.transcription.transcriptionProvider ?? .parakeet)
    }

    /// True when the model is loaded in memory right now. Cloud: always.
    func isResident(_ model: VoiceModelInfo) -> Bool {
        !model.isOnDevice || resident.contains(model.id)
    }

    /// The engine for a model. On-device engines are made once per model;
    /// cloud engines are built from settings each time.
    func engine(for model: VoiceModelInfo, settings: AppSettings?) throws -> any BatchTranscriptionEngine {
        if let factory {
            if model.isOnDevice, let existing = engines[model.id] { return existing }
            let made = try factory(model, settings)
            if model.isOnDevice { engines[model.id] = made }
            return made
        }

        switch model.kind {
        case .cloud(let choice):
            guard let provider = CloudTranscription.provider(for: choice, settings: settings) else {
                throw TranscriptionFailure.notConfigured(choice.displayName)
            }
            return CloudBatchEngine(provider: provider)
        case .parakeet(.v3):
            return parakeetV3()
        case .parakeet(let version):
            if let existing = engines[model.id] { return existing }
            let made = TranscriptionEngine(version: version)
            engines[model.id] = made
            return made
        case .whisperKit(let variant):
            if let existing = engines[model.id] { return existing }
            let made = WhisperKitEngine(variant: variant)
            engines[model.id] = made
            return made
        }
    }

    /// The shared Parakeet V3 engine (also `engine`).
    private func parakeetV3() -> TranscriptionEngine {
        if let engine { return engine }
        let made = TranscriptionEngine()
        engine = made
        engines[VoiceModels.parakeetV3.id] = made
        return made
    }

    // MARK: - Preparation

    /// Downloads and loads Parakeet V3 in the background, reporting
    /// progress through `onEvent`. Idempotent: safe to call from the
    /// onboarding Welcome step (to start early) and again from setup. A
    /// failed attempt allows a retry.
    ///
    /// - Parameter settings: Read for vocabulary boosting and keep-alive.
    func prepare(
        settings: AppSettings?,
        onEvent: @escaping @MainActor @Sendable (ModelPreparationEvent) -> Void
    ) {
        guard !preparationStarted else { return }
        preparationStarted = true
        if let settings { self.settings = settings }

        diagLog("[Parrot:Model] Starting model download/load task...")
        let model = VoiceModels.parakeetV3
        Task {
            do {
                onEvent(.progress(0))
                _ = try await ensureLoaded(model, settings: settings, allowDownload: true) { fraction in
                    Task { @MainActor in onEvent(.progress(fraction * 0.9)) }
                }
                diagLog("[Parrot:Model] Pre-warm complete, model READY")
                isModelReady = true
                onEvent(.ready)
            } catch {
                diagLog("[Parrot:Model] FAILED: \(error)")
                preparationStarted = false
                onEvent(.failed(error))
            }
        }
    }

    /// Starts loading a dictation's model while the user speaks, so the
    /// final pass does not wait. Never downloads. Errors are logged.
    func preload(_ model: VoiceModelInfo, settings: AppSettings?) {
        guard model.isOnDevice, !resident.contains(model.id), loads[model.id] == nil else { return }
        Task {
            do {
                _ = try await ensureLoaded(model, settings: settings)
            } catch {
                diagLog("[Parrot:Router] Preload of \(model.name) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Keeps a model from unloading until `release`, for example while a
    /// recording that will use it is in progress. Calls must pair.
    func retain(_ model: VoiceModelInfo) {
        guard model.isOnDevice else { return }
        beginUse(model.id)
    }

    func release(_ model: VoiceModelInfo) {
        guard model.isOnDevice else { return }
        endUse(model.id)
    }

    /// Downloads a model without loading it (the mode editor's Download
    /// button). Single flight per model.
    func download(
        _ model: VoiceModelInfo,
        settings: AppSettings?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard model.isOnDevice else { return }
        let engine = try engine(for: model, settings: settings)
        try await download(model, engine: engine, progress: progress)
    }

    /// True when the model's files are on disk. Cloud: always.
    func isDownloaded(_ model: VoiceModelInfo, settings: AppSettings?) async -> Bool {
        guard model.isOnDevice else { return true }
        guard let engine = try? engine(for: model, settings: settings) else { return false }
        return await engine.isDownloaded()
    }

    /// Returns the model's engine, loaded. Joins a load already running.
    /// - Parameter allowDownload: When false (every dictation), a model
    ///   that is not on disk throws `.modelNotDownloaded`, or
    ///   `.engineNotReady` for Parakeet V3 while its first download runs.
    func ensureLoaded(
        _ model: VoiceModelInfo,
        settings: AppSettings?,
        allowDownload: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> any BatchTranscriptionEngine {
        if let settings { self.settings = settings }
        let engine = try engine(for: model, settings: settings)
        guard model.isOnDevice, !resident.contains(model.id) else { return engine }

        if loads[model.id] == nil, !(await engine.isDownloaded()) {
            guard allowDownload else {
                throw model.id == VoiceModels.parakeetV3.id
                    ? TranscriptionFailure.engineNotReady
                    : TranscriptionFailure.modelNotDownloaded(model.name)
            }
            try await download(model, engine: engine, progress: progress)
        }
        try await load(model, engine: engine)
        return engine
    }

    private func download(
        _ model: VoiceModelInfo,
        engine: any BatchTranscriptionEngine,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let running = downloads[model.id] {
            try await running.value
            return
        }
        let task = Task {
            defer { downloads[model.id] = nil }
            diagLog("[Parrot:Router] Downloading \(model.name)")
            try await engine.download(progress: progress)
        }
        downloads[model.id] = task
        try await task.value
    }

    private func load(_ model: VoiceModelInfo, engine: any BatchTranscriptionEngine) async throws {
        if resident.contains(model.id) { return }
        let task: Task<Void, Error>
        if let running = loads[model.id] {
            diagLog("[Parrot:Router] Waiting for in-progress load of \(model.name)")
            task = running
        } else {
            task = Task {
                defer { loads[model.id] = nil }
                let started = Date()
                try await engine.load()
                await engine.applyVocabulary(vocabulary.entries, enabled: boostingEnabled)
                resident.insert(model.id)
                diagLog("[Parrot:Router] \(model.name) loaded in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                scheduleUnloadIfIdle(model.id)
            }
            loads[model.id] = task
        }
        try await Timeout.run(
            seconds: loadTimeout,
            failure: TranscriptionFailure.loadTimedOut(model.name, loadTimeout)
        ) {
            try await task.value
        }
    }

    // MARK: - Transcription

    /// Transcribes with a model, loading it first when needed. If the
    /// engine finds its model gone, it reloads and retries once.
    func transcribe(
        _ samples: [Float],
        model: VoiceModelInfo,
        options: TranscriptionOptions,
        settings: AppSettings?
    ) async throws -> TranscriptOutput {
        var engine = try await ensureLoaded(model, settings: settings)
        beginUse(model.id)
        defer { endUse(model.id) }

        await engine.applyVocabulary(vocabulary.entries, enabled: boostingEnabled)
        do {
            return try await engine.transcribe(samples, options: options)
        } catch let error where TranscriptionFailure.classify(error) == .engineNotReady && model.isOnDevice {
            diagLog("[Parrot:Router] \(model.name) was not loaded, reloading and retrying")
            resident.remove(model.id)
            engine = try await ensureLoaded(model, settings: settings)
            return try await engine.transcribe(samples, options: options)
        }
    }

    /// Opens live text on a loaded model that streams. The model counts as
    /// in use (no keep-alive unload) until the stream ends.
    func startLiveStream(
        _ model: VoiceModelInfo,
        options: TranscriptionOptions,
        settings: AppSettings?,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> any LiveTranscriptionStream {
        let engine = try await ensureLoaded(model, settings: settings)
        guard let streaming = engine as? any StreamingTranscriptionEngine, model.supportsRealtime else {
            throw TranscriptionFailure.notConfigured("Live text for \(model.name)")
        }
        beginUse(model.id)
        do {
            let stream = try await streaming.startLiveStream(options: options, onUpdate: onUpdate)
            return TrackedLiveStream(stream) { [weak self] in
                Task { @MainActor in self?.endUse(model.id) }
            }
        } catch {
            endUse(model.id)
            throw error
        }
    }

    private var boostingEnabled: Bool {
        settings?.vocabulary.vocabularyBoostingEnabled ?? false
    }

    // MARK: - Keep-Alive

    private var keepAliveSeconds: TimeInterval {
        keepAliveOverride ?? settings?.transcription.activeDuration ?? 60
    }

    private func beginUse(_ id: String) {
        useCounts[id, default: 0] += 1
        unloadTimers[id]?.cancel()
        unloadTimers[id] = nil
    }

    private func endUse(_ id: String) {
        useCounts[id] = max(0, useCounts[id, default: 0] - 1)
        scheduleUnloadIfIdle(id)
    }

    /// Arms the unload timer when the model is loaded and unused. A
    /// duration of zero or less keeps models loaded.
    private func scheduleUnloadIfIdle(_ id: String) {
        guard useCounts[id, default: 0] == 0, resident.contains(id) else { return }
        let delay = keepAliveSeconds
        guard delay > 0 else { return }
        unloadTimers[id]?.cancel()
        unloadTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle(id)
        }
    }

    private func unloadIfIdle(_ id: String) async {
        unloadTimers[id] = nil
        guard useCounts[id, default: 0] == 0, resident.contains(id), loads[id] == nil,
              let engine = engines[id]
        else { return }
        resident.remove(id)
        diagLog("[Parrot:Router] Unloading idle voice model \(id)")
        await engine.unload()
    }
}

/// Forwards to a live stream and reports once when it ends.
private final class TrackedLiveStream: LiveTranscriptionStream, @unchecked Sendable {
    private let inner: any LiveTranscriptionStream
    private let lock = NSLock()
    private var onEnd: (@Sendable () -> Void)?

    init(_ inner: any LiveTranscriptionStream, onEnd: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onEnd = onEnd
    }

    func append(_ samples: [Float]) {
        inner.append(samples)
    }

    func finish() async throws -> String {
        defer { ended() }
        return try await inner.finish()
    }

    func cancel() async {
        await inner.cancel()
        ended()
    }

    private func ended() {
        lock.lock()
        let callback = onEnd
        onEnd = nil
        lock.unlock()
        callback?()
    }
}
