import Foundation

/// Turns the session's audio into `rawTranscript`, `text`, `segments`,
/// `speakers` and `language` (ASR).
///
/// The router picks the mode's voice model (or the global provider). Each
/// model gets up to 3 tries, 200 ms apart times the attempt number, for
/// retryable failures. When any other model than on-device Parakeet V3
/// fails (a cloud error, missing settings, a model not downloaded), the
/// dictation falls back to Parakeet V3 with a non-blocking toast, so it is
/// never lost. Load and recognition times land in `session.timings`.
///
/// - A Deepgram or ElevenLabs live session supplies the transcript
///   itself; when it produced no text (or was lost) the recording is
///   transcribed in one batch pass instead.
/// - Audio longer than the model takes at once (and file runs longer than
///   5 minutes) is cut at quiet points and transcribed piece by piece.
/// - With "Identify speakers" on, segments get speakers and the text gets
///   "Speaker N:" labels when more than one speaker talks.
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

        var output: TranscriptOutput
        if let live = await realtimeTranscript(for: model, session: session, options: options) {
            output = live
        } else {
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
        }

        var segments = output.segments
        if let map = session.speechTimeMap {
            segments = map.mapSegments(segments)
        }
        session.rawTranscript = output.text
        session.text = output.text
        session.segments = segments
        session.language = output.language ?? options.language

        if session.mode?.diarize == true {
            await separateSpeakers(session)
        }
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

    // MARK: - Realtime

    /// The live session's text when this dictation streamed to a cloud
    /// vendor and the session finished with text. Nil means "transcribe
    /// the recording in a batch pass".
    private func realtimeTranscript(
        for model: VoiceModelInfo,
        session: DictationSession,
        options: TranscriptionOptions
    ) async -> TranscriptOutput? {
        guard model.usesRealtimeFinal, session.realtimeModelID == model.id,
              let pending = session.realtimeTranscript
        else { return nil }
        let started = Date()
        let text = await pending.value
        session.timings[TimingKey.recognition, default: 0] += Date().timeIntervalSince(started)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagLog("[Parrot:Transcribe] Realtime \(model.name) gave no text, falling back to batch transcription")
            return nil
        }
        session.voiceModelID = model.id
        session.transcriptionAttempts += 1
        return TranscriptOutput(text: text, language: options.language)
    }

    // MARK: - Speakers

    private func separateSpeakers(_ session: DictationSession) async {
        let outcome = await services.transcription.diarization.assignSpeakers(
            segments: session.segments, recording: session.samples
        )
        session.segments = outcome.segments
        session.speakers = outcome.speakers
        if let warning = outcome.warning { session.warnings.append(warning) }
        if outcome.speakers.count > 1 {
            session.text = DiarizationService.labelledText(outcome.segments)
        }
    }

    // MARK: - Attempts

    /// The longest piece of audio sent at once for this model and session.
    static func chunkLimit(for model: VoiceModelInfo, isFromFile: Bool) -> TimeInterval? {
        let fileLimit = isFromFile ? AudioChunker.fileChunkSeconds : nil
        switch (model.maxChunkSeconds, fileLimit) {
        case let (model?, file?): return min(model, file)
        case let (model?, nil): return model
        case let (nil, file?): return file
        case (nil, nil): return nil
        }
    }

    /// Transcribes the audio in one piece, or in pieces cut at quiet
    /// moments when it is longer than the model or file run allows.
    private func transcribe(
        _ audio: [Float],
        model: VoiceModelInfo,
        options: TranscriptionOptions,
        session: DictationSession
    ) async throws -> TranscriptOutput {
        guard let limit = Self.chunkLimit(for: model, isFromFile: session.isFromFile) else {
            return try await transcribePiece(audio, model: model, options: options, session: session)
        }
        let ranges = AudioChunker.ranges(for: audio.count, samples: audio, maxSeconds: limit)
        guard ranges.count > 1 else {
            return try await transcribePiece(audio, model: model, options: options, session: session)
        }

        diagLog("[Parrot:Transcribe] \(String(format: "%.0f", Double(audio.count) / AudioFrame.sampleRate))s of audio in \(ranges.count) pieces for \(model.name)")
        var texts: [String] = []
        var segments: [TranscriptSegment] = []
        var language: String?
        for (index, range) in ranges.enumerated() {
            if session.isCancelled { throw TranscriptionFailure.cancelled }
            let piece = try await transcribePiece(Array(audio[range]), model: model, options: options, session: session)
            let offset = Double(range.lowerBound) / AudioFrame.sampleRate
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            segments += piece.segments.map { segment in
                var moved = segment
                moved.start += offset
                moved.end += offset
                return moved
            }
            language = language ?? piece.language
            if session.isFromFile {
                services.live.processingProgress = Double(index + 1) / Double(ranges.count)
            }
        }
        return TranscriptOutput(text: texts.joined(separator: " "), segments: segments, language: language)
    }

    /// Loads the model (timed as load) and transcribes (timed as
    /// recognition), retrying per the policy.
    private func transcribePiece(
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
