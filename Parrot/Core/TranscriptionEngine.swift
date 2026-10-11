import FluidAudio
import Foundation

/// Wraps FluidAudio's AsrManager for one Parakeet checkpoint (V3 by
/// default, or V2), handling model download, loading, pre-warming,
/// unloading and transcription.
///
/// An actor so model preparation, boosting reconfiguration and transcription
/// never touch the manager or the boosting session concurrently, and so the
/// main-actor AppState can hand work to it without blocking the UI.
actor TranscriptionEngine {

    // MARK: - Types

    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case error(String)
    }

    // MARK: - Properties

    /// Which Parakeet checkpoint this engine runs.
    nonisolated let version: ParakeetVersion

    private(set) var modelStatus: ModelStatus = .notDownloaded
    private var asrManager: AsrManager?
    /// The loaded CoreML models, shared with live streams.
    private var models: AsrModels?
    private var modelsLoaded = false
    /// CTC keyword spotting plus transcript rescoring. Since FluidAudio 0.17
    /// the batch AsrManager no longer owns boosting, so the engine applies it
    /// after each decode. Nil when boosting is off.
    private var vocabularyBoosting: VocabularyBoostingSession?
    /// True once vocabulary boosting has been configured on the ASR manager.
    private(set) var vocabularyBoostingActive = false
    /// The boosting lines and toggle last applied, so an unchanged
    /// vocabulary is not reconfigured on every dictation.
    private var vocabularySignature: String?

    /// Rescoring without FluidAudio's spotter-anchored rescue pass, which the
    /// library documents as reproducing its pre-0.14.5 behavior. With the
    /// rescue on, a single term rewrote unrelated speech ("Hello world" became
    /// "GitHub") at near-zero string similarity.
    static let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)

    /// Where FluidAudio caches the Parakeet V3 model.
    static var modelCacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    /// Where FluidAudio caches this engine's checkpoint.
    nonisolated var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: asrVersion)
    }

    private nonisolated var asrVersion: AsrModelVersion {
        version == .v2 ? .v2 : .v3
    }

    init(version: ParakeetVersion = .v3) {
        self.version = version
    }

    // MARK: - Model Lifecycle

    /// True when every model file for this checkpoint is on disk.
    func isDownloaded() -> Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }

    /// Downloads the checkpoint into FluidAudio's cache. Returns at once
    /// when it is already there.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        modelStatus = .downloading(progress: 0)
        do {
            try await AsrModels.download(version: asrVersion) { update in
                progress(update.fractionCompleted)
            }
        } catch {
            modelStatus = .error(error.localizedDescription)
            throw error
        }
    }

    /// Loads the cached checkpoint and prewarms it. No-op when loaded.
    func load() async throws {
        guard !modelsLoaded else { return }
        do {
            let models = try await AsrModels.load(from: cacheDirectory, version: asrVersion)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.asrManager = manager
            self.models = models
            self.modelsLoaded = true
            modelStatus = .ready
            try await prewarm()
        } catch {
            modelStatus = .error(error.localizedDescription)
            throw error
        }
    }

    /// Frees the model and the boosting session. `load` brings them back.
    func unload() async {
        guard modelsLoaded else { return }
        await asrManager?.cleanup()
        asrManager = nil
        models = nil
        modelsLoaded = false
        vocabularyBoosting = nil
        vocabularyBoostingActive = false
        vocabularySignature = nil
        diagLog("[Parrot:Model] Parakeet \(version.rawValue) unloaded")
    }

    /// Downloads (if needed) and loads the model.
    ///
    /// - Parameter progressHandler: Optional closure invoked with download
    ///   progress (0...1).
    /// - Throws: If the download or model load fails.
    func prepareModel(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !modelsLoaded else { return }
        progressHandler?(0)
        try await download { progressHandler?($0 * 0.9) }
        try await load()
        progressHandler?(1.0)
    }

    /// Pre-warms the model by running a dummy 1-second inference of silence.
    ///
    /// This triggers CoreML compilation and Neural Engine allocation before
    /// the user's first real transcription.
    func prewarm() async throws {
        guard let manager = asrManager else { return }

        // 1 second of silence at 16kHz.
        let silentSamples = [Float](repeating: 0, count: 16_000)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe(silentSamples, decoderState: &decoderState)
    }

    // MARK: - Transcription

    /// Transcribes an array of 16kHz mono Float32 samples to text.
    ///
    /// - Parameter samples: Raw audio samples at 16kHz sample rate.
    /// - Returns: The transcribed text.
    /// - Throws: If the engine is not ready or transcription fails.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, options: TranscriptionOptions()).text
    }

    /// Transcribes samples into text and sentence segments. A fixed
    /// language becomes V3's script hint; V2 ignores it.
    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        guard let manager = asrManager, modelsLoaded else {
            throw TranscriptionEngineError.notReady
        }

        // Each dictation is an independent utterance, so it starts from a
        // fresh decoder state (FluidAudio's batch path does the same per chunk).
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = options.language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: hint)

        let timings = result.tokenTimings ?? []
        let words = buildWordTimings(from: timings).map {
            TranscriptSegmenter.Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        var output = TranscriptOutput(
            text: result.text,
            segments: TranscriptSegmenter.segments(from: words),
            language: options.language
        )

        guard let boosting = vocabularyBoosting, !timings.isEmpty else { return output }

        // Rescoring returns nil when nothing matched or CTC inference failed;
        // either way the decoder's own text stands.
        let rescored = await boosting.rescore(
            text: result.text, tokenTimings: timings, audioSamples: samples
        )
        if let rescored { output.text = rescored.text }
        return output
    }

    // MARK: - Live Text

    /// Opens a live stream on the loaded models (no second load).
    func startLiveStream(
        options: TranscriptionOptions,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> any LiveTranscriptionStream {
        guard let models, modelsLoaded else { throw TranscriptionEngineError.notReady }
        return try await ParakeetLiveStream.start(
            models: models,
            version: version,
            language: options.language.flatMap { Language(rawValue: $0) },
            onUpdate: onUpdate
        )
    }

    // MARK: - Vocabulary Boosting

    /// Applies the vocabulary store, reconfiguring only when the boosted
    /// lines or the toggle changed since the last call.
    func applyVocabulary(_ entries: [VocabularyEntry], enabled: Bool) async {
        guard modelsLoaded else { return }
        let signature = Self.signature(lines: Self.simpleFormatLines(from: entries), enabled: enabled)
        guard signature != vocabularySignature else { return }
        await configureVocabulary(entries: entries, enabled: enabled)
    }

    private static func signature(lines: [String], enabled: Bool) -> String {
        enabled ? lines.joined(separator: "\n") : ""
    }

    /// Enables or disables decode-time vocabulary boosting so proper nouns and
    /// jargon are recognized correctly, not just find/replaced afterwards.
    ///
    /// Enabling lazily downloads an auxiliary CTC model (~110M params, cached).
    /// All failures are swallowed (logged): dictation must never break because
    /// boosting could not be configured. Only affects the on-device Parakeet
    /// path; cloud transcription is unaffected.
    ///
    /// - Parameters:
    ///   - entries: Vocabulary entries; disabled/empty ones are ignored.
    ///   - enabled: Master toggle. When false, boosting is turned off.
    func configureVocabulary(entries: [VocabularyEntry], enabled: Bool) async {
        guard asrManager != nil, modelsLoaded else { return }

        let lines = Self.simpleFormatLines(from: entries)
        // Recorded even when configuration fails, so a broken term list is
        // not retried (and the CTC model reloaded) on every dictation.
        vocabularySignature = Self.signature(lines: lines, enabled: enabled)
        guard enabled, !lines.isEmpty else {
            vocabularyBoosting = nil
            vocabularyBoostingActive = false
            return
        }

        do {
            // Write the terms to a temp simple-format file and let FluidAudio
            // download CTC models and tokenize each term.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("parrot-vocab-\(UUID().uuidString).txt")
            try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let (vocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: tmp.path)
            vocabularyBoosting = try await VocabularyBoostingSession(
                vocabulary: vocab, ctcModels: ctcModels, config: Self.rescorerConfig
            )
            vocabularyBoostingActive = true
            diagLog("[Parrot:Vocab] Boosting configured with \(vocab.terms.count) terms")
        } catch {
            vocabularyBoosting = nil
            vocabularyBoostingActive = false
            diagLog("[Parrot:Vocab] Boosting configuration failed: \(error)")
        }
    }

    /// Builds FluidAudio simple-format lines from Parrot vocabulary entries.
    /// Each line boosts the corrected form (the replacement) and lists the
    /// original as an alias when it differs, so a common mishearing maps onto
    /// the intended spelling. Pure and side-effect-free for testing.
    static func simpleFormatLines(from entries: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for entry in entries where entry.isEnabled {
            let term = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let original = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
            if !original.isEmpty, original.lowercased() != term.lowercased() {
                lines.append("\(term): \(original)")
            } else {
                lines.append(term)
            }
        }
        return lines
    }
}

extension TranscriptionEngine: BatchTranscriptionEngine, StreamingTranscriptionEngine {}

// MARK: - Errors

enum TranscriptionEngineError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Transcription engine is not ready. The model has not been downloaded or loaded."
        }
    }
}
