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
