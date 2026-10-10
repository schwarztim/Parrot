import Foundation

/// Progress of the one-time model download, load and prewarm.
enum ModelPreparationEvent {
    case progress(Double)
    case ready
    case failed(Error)
}

/// Owns the on-device transcription engine and its preparation.
///
/// Today there is one engine (Parakeet V3). ASR grows this into the
/// per-mode engine router.
@MainActor
final class TranscriptionRouter {

    /// The Parakeet engine, created by the first `prepare` call.
    private(set) var engine: TranscriptionEngine?

    /// True once the model is downloaded, loaded and prewarmed.
    private(set) var isModelReady = false

    /// Guards `prepare` against launching more than one download.
    private var preparationStarted = false

    private let vocabulary: VocabularyManager

    init(vocabulary: VocabularyManager) {
        self.vocabulary = vocabulary
    }

    /// Transcribes an audio file opened with Parrot (Open With, a file
    /// URL). Stub: ignored until file transcription lands.
    func openFile(_ url: URL) {}

    /// Downloads and loads the Parakeet model in the background, reporting
    /// progress through `onEvent`. Idempotent: safe to call from the
    /// onboarding Welcome step (to start early) and again from setup. A
    /// failed attempt allows a retry.
    ///
    /// - Parameter settings: Read after prewarm for the vocabulary boosting
    ///   toggle.
    func prepare(
        settings: AppSettings?,
        onEvent: @escaping @MainActor @Sendable (ModelPreparationEvent) -> Void
    ) {
        guard !preparationStarted else { return }
        preparationStarted = true

        let engine = self.engine ?? TranscriptionEngine()
        self.engine = engine

        diagLog("[Parrot:Model] Starting model download/load task...")
        // Inherits the main actor: the download, load and prewarm run inside
        // the engine actor, and every line between awaits is back on main.
        Task { [weak self] in
            do {
                try await engine.prepareModel { progress in
                    Task { @MainActor in
                        onEvent(.progress(progress))
                    }
                }

                try await engine.prewarm()
                diagLog("[Parrot:Model] Pre-warm complete, model READY")

                // Configure vocabulary boosting once the model is ready.
                await engine.configureVocabulary(
                    entries: self?.vocabulary.entries ?? [],
                    enabled: settings?.vocabulary.vocabularyBoostingEnabled ?? false
                )

                guard let self else { return }
                isModelReady = true
                onEvent(.ready)
            } catch {
                diagLog("[Parrot:Model] FAILED: \(error)")
                guard let self else { return }
                preparationStarted = false
                onEvent(.failed(error))
            }
        }
    }
}
