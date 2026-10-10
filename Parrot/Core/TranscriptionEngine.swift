import FluidAudio
import Foundation

/// Wraps FluidAudio's AsrManager, handling model download, pre-warming, and transcription.
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

    private(set) var modelStatus: ModelStatus = .notDownloaded
    private var asrManager: AsrManager?
    private var modelsLoaded = false
    /// CTC keyword spotting plus transcript rescoring. Since FluidAudio 0.17
    /// the batch AsrManager no longer owns boosting, so the engine applies it
    /// after each decode. Nil when boosting is off.
    private var vocabularyBoosting: VocabularyBoostingSession?
    /// True once vocabulary boosting has been configured on the ASR manager.
    private(set) var vocabularyBoostingActive = false

    /// Rescoring without FluidAudio's spotter-anchored rescue pass, which the
    /// library documents as reproducing its pre-0.14.5 behavior. With the
    /// rescue on, a single term rewrote unrelated speech ("Hello world" became
    /// "GitHub") at near-zero string similarity.
    static let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)

    /// Where FluidAudio caches the Parakeet V3 model.
    static var modelCacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    // MARK: - Model Lifecycle

    /// Downloads and loads the Parakeet V3 model via FluidAudio's built-in
    /// download + caching mechanism.
    ///
    /// - Parameter progressHandler: Optional closure invoked with download
    ///   progress (0...1). Only called during actual download.
    /// - Throws: If the download or model load fails.
    func prepareModel(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !modelsLoaded else { return }

        modelStatus = .downloading(progress: 0)
        progressHandler?(0)

        do {
            // FluidAudio handles caching internally. downloadAndLoad will
            // skip the download if the model is already cached.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            progressHandler?(0.9)

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.asrManager = manager
            self.modelsLoaded = true
            modelStatus = .ready
            progressHandler?(1.0)
        } catch {
            modelStatus = .error(error.localizedDescription)
            throw error
        }
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

    /// Transcribes an array of 16kHz mono Float32 samples to text.
    ///
    /// - Parameter samples: Raw audio samples at 16kHz sample rate.
    /// - Returns: The transcribed text.
    /// - Throws: If the engine is not ready or transcription fails.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager = asrManager, modelsLoaded else {
            throw TranscriptionEngineError.notReady
        }

        // Each dictation is an independent utterance, so it starts from a
        // fresh decoder state (FluidAudio's batch path does the same per chunk).
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)

        guard let boosting = vocabularyBoosting,
              let timings = result.tokenTimings, !timings.isEmpty
        else { return result.text }

        // Rescoring returns nil when nothing matched or CTC inference failed;
        // either way the decoder's own text stands.
        let rescored = await boosting.rescore(
            text: result.text, tokenTimings: timings, audioSamples: samples
        )
        return rescored?.text ?? result.text
    }

    // MARK: - Vocabulary Boosting

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
