import Foundation

/// Turns the session's audio into `rawTranscript`, `text`, `segments` and
/// `language` (ASR).
///
/// The router picks the mode's voice model (or the global provider). Each
/// model gets up to 3 tries, 200 ms apart times the attempt number, for
/// retryable failures. When any other model than on-device Parakeet V3
/// fails (a cloud error, missing settings, a model not downloaded), the
/// dictation falls back to Parakeet V3 with a non-blocking toast, so it is
/// never lost. Load and recognition times land in `session.timings`.
@MainActor
final class TranscribeStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .abort }
    var runsAfterFinish: Bool { false }

    /// Overridable for tests.
    var retryPolicy = RetryPolicy.standard

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        let audio = session.transcriptionAudio ?? session.samples
        guard !audio.isEmpty else {
            // A reprocess run may arrive with text and no audio.
            return session.text.isEmpty ? .finish(.empty) : .continue
        }

        let router = services.transcription
        let settings = services.settings
        let model = router.resolveModel(for: session.mode, settings: settings)
        let options = TranscriptionOptions(mode: session.mode)

        let output: TranscriptOutput
        do {
            output = try await transcribe(audio, model: model, options: options, session: session)
        } catch let failure as TranscriptionFailure {
            let fallback = VoiceModels.parakeetV3
            guard model.id != fallback.id, failure != .cancelled,
                  await router.isDownloaded(fallback, settings: settings)
            else {
                throw failure
            }
            diagLog("[Parrot:Transcribe] \(model.name) FAILED: \(failure.localizedDescription)")
            services.showTransientError(Self.fallbackMessage(for: model, failure: failure))
            output = try await transcribe(audio, model: fallback, options: options, session: session)
        }

        var segments = output.segments
        if let map = session.speechTimeMap {
            segments = map.mapSegments(segments)
        }
        session.rawTranscript = output.text
        session.text = output.text
        session.segments = segments
        session.language = output.language ?? options.language
        return .continue
    }

    /// The toast shown when a dictation falls back to on-device Parakeet.
    static func fallbackMessage(for model: VoiceModelInfo, failure: TranscriptionFailure) -> String {
        switch failure {
        case .notConfigured:
            return "\(model.name) is not configured, used on-device Parakeet instead."
        case .modelNotDownloaded:
            return "\(model.name) is not downloaded, used on-device Parakeet instead."
        default:
            return "\(model.name) failed, used on-device Parakeet instead. \(failure.localizedDescription)"
        }
    }

    // MARK: - Attempts

    /// Loads the model (timed as load) and transcribes (timed as
    /// recognition), retrying per the policy.
    private func transcribe(
        _ audio: [Float],
        model: VoiceModelInfo,
        options: TranscriptionOptions,
        session: DictationSession
    ) async throws -> TranscriptOutput {
        let router = services.transcription
        let settings = services.settings
        session.voiceModelID = model.id

        return try await retryPolicy.run(onFailure: { attempt, failure in
            diagLog("[Parrot:Transcribe] Attempt \(attempt)/\(self.retryPolicy.maxAttempts) with \(model.name) failed: \(failure.localizedDescription)")
            if !failure.isRetryable {
                diagLog("[Parrot:Transcribe] Non-retryable transcription error, skipping retry")
            }
        }) { _ in
            session.transcriptionAttempts += 1
            let loadStarted = Date()
            _ = try await router.ensureLoaded(model, settings: settings)
            session.timings[TimingKey.load, default: 0] += Date().timeIntervalSince(loadStarted)

            let started = Date()
            let output = try await router.transcribe(audio, model: model, options: options, settings: settings)
            session.timings[TimingKey.recognition, default: 0] += Date().timeIntervalSince(started)
            return output
        }
    }

    /// Keys this stage adds to `session.timings`.
    enum TimingKey {
        /// Waiting for the voice model to load.
        static let load = "TranscribeStage.load"
        /// Running the recognizer, every attempt included.
        static let recognition = "TranscribeStage.recognition"
    }
}

// MARK: - Session Attachments

private enum VoiceModelIDKey: SessionKey {
    static var defaultValue: String? { nil }
}

private enum TranscriptionAttemptsKey: SessionKey {
    static var defaultValue: Int { 0 }
}

extension DictationSession {
    /// The `VoiceModels` id that produced the transcript (after any
    /// fallback). For meta.json and history.
    var voiceModelID: String? {
        get { self[VoiceModelIDKey.self] }
        set { self[VoiceModelIDKey.self] = newValue }
    }

    /// The voice model's display name, from `voiceModelID`.
    var voiceModelName: String? {
        voiceModelID.flatMap { VoiceModels.model(id: $0)?.name }
    }

    /// Recognizer runs this session took, fallback included.
    var transcriptionAttempts: Int {
        get { self[TranscriptionAttemptsKey.self] }
        set { self[TranscriptionAttemptsKey.self] = newValue }
    }
}
