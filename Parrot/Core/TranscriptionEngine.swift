import FluidAudio
import Foundation

/// Wraps FluidAudio's AsrManager, handling model download, pre-warming, and transcription.
final class TranscriptionEngine {

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
    /// True once vocabulary boosting has been configured on the ASR manager.
    private(set) var vocabularyBoostingActive = false

    // MARK: - Model Lifecycle

    /// Downloads and loads the Parakeet V3 model via FluidAudio's built-in
    /// download + caching mechanism.
    ///
    /// - Parameter progressHandler: Optional closure invoked with download
    ///   progress (0...1). Only called during actual download.
    /// - Throws: If the download or model load fails.
    func prepareModel(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard !modelsLoaded else { return }

        modelStatus = .downloading(progress: 0)
        progressHandler?(0)

        do {
            // FluidAudio handles caching internally. downloadAndLoad will
            // skip the download if the model is already cached.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            progressHandler?(0.9)

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
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
        _ = try await manager.transcribe(silentSamples)
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

        let result = try await manager.transcribe(samples)
        return result.text
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
        guard let manager = asrManager, modelsLoaded else { return }

        let lines = Self.simpleFormatLines(from: entries)
        guard enabled, !lines.isEmpty else {
            await manager.disableVocabularyBoosting()
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
            try await manager.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctcModels)
            vocabularyBoostingActive = true
            diagLog("[Parrot:Vocab] Boosting configured with \(vocab.terms.count) terms")
        } catch {
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
