import Foundation

/// Turns `session.samples` into `rawTranscript` and `text` (ASR).
///
/// Uses the provider selected in settings. Cloud failures (or missing cloud
/// configuration) fall back to the local Parakeet engine when it is ready,
/// with a non-blocking error toast, so dictation is never lost.
@MainActor
final class TranscribeStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .abort }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        let text = try await transcribe(session.samples)
        session.rawTranscript = text
        session.text = text
        return .continue
    }

    // MARK: - Provider Selection

    private func transcribe(_ samples: [Float]) async throws -> String {
        guard let engine = services.transcription.engine else {
            throw TranscriptionError.engineNotReady
        }

        let choice = services.settings?.transcription.transcriptionProvider ?? .parakeet
        guard choice != .parakeet else {
            return try await engine.transcribe(samples)
        }

        guard let cloud = cloudTranscriber(for: choice) else {
            services.showTransientError(
                "\(choice.displayName) is not configured, used on-device Parakeet instead."
            )
            return try await engine.transcribe(samples)
        }

        do {
            return try await cloud.transcribe(samples)
        } catch {
            diagLog("[Parrot:AppState] Cloud transcription FAILED: \(error)")
            guard services.transcription.isModelReady else { throw error }
            services.showTransientError(
                "\(choice.displayName) failed, used on-device Parakeet instead. \(error.localizedDescription)"
            )
            return try await engine.transcribe(samples)
        }
    }

    /// Builds the cloud transcriber for the given choice, or nil when its
    /// settings are incomplete.
    private func cloudTranscriber(for choice: TranscriptionProviderChoice) -> TranscriptionProvider? {
        guard let settings = services.settings else { return nil }
        let transcription = settings.transcription
        let refinement = settings.refinement
        switch choice {
        case .parakeet:
            return nil
        case .openAI:
            let apiKey = settings.credentials.key(for: .openAI)
            guard !apiKey.isEmpty, !transcription.openAITranscriptionModel.isEmpty else { return nil }
            return OpenAITranscriber(apiKey: apiKey, model: transcription.openAITranscriptionModel)
        case .azureWhisper:
            let apiKey = settings.credentials.key(for: .azureOpenAI)
            guard !refinement.azureOpenAIEndpoint.isEmpty,
                  !apiKey.isEmpty,
                  !transcription.azureWhisperDeployment.isEmpty
            else { return nil }
            return AzureWhisperTranscriber(
                endpoint: refinement.azureOpenAIEndpoint,
                apiKey: apiKey,
                deployment: transcription.azureWhisperDeployment,
                apiVersion: refinement.azureOpenAIAPIVersion
            )
        }
    }
}
