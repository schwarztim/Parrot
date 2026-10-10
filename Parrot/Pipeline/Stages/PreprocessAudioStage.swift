import Foundation

/// Silence removal, the short-clip gate and dynamic normalization before
/// transcription (ASR).
///
/// `session.samples` is never changed: the recording stays whole for the
/// WAV file, history and duration. The audio to transcribe goes in
/// `session.transcriptionAudio`, with `session.speechTimeMap` to map
/// segment times back. Every detector problem fails open: the full
/// recording is transcribed.
@MainActor
final class PreprocessAudioStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        guard !session.samples.isEmpty, let settings = services.settings?.transcription else {
            return .continue
        }

        let duration = session.duration
        let wantsTrim = settings.silenceRemoval
        let wantsGate = settings.shortClipGate && duration <= ShortClipGate.maxDuration
        var audio = session.samples
        var changed = false

        if wantsTrim || wantsGate {
            if services.vad.isReady {
                do {
                    let regions = try await services.vad.speechRegions(in: session.samples)
                    let merged = SilenceTrimmer.merge(regions, limit: session.samples.count)
                    let speechSamples = merged.reduce(0) { $0 + $1.count }
                    session.speechSeconds = Double(speechSamples) / AudioFrame.sampleRate
                    diagLog(
                        "[Parrot:VAD] duration=\(String(format: "%.2f", duration))s speech=\(String(format: "%.2f", session.speechSeconds ?? 0))s regions=\(merged.count)"
                    )

                    if wantsGate, ShortClipGate.shouldSkip(duration: duration, speechSamples: speechSamples) {
                        diagLog("[Parrot:VAD] Short-clip gate: no speech detected, skipping transcription")
                        return .finish(.empty)
                    }

                    // No speech found in a longer clip: keep everything
                    // rather than risk dropping quiet words.
                    if wantsTrim, !merged.isEmpty, speechSamples < session.samples.count {
                        let trimmed = SilenceTrimmer.trim(session.samples, keeping: merged)
                        audio = trimmed.samples
                        session.speechTimeMap = trimmed.map
                        changed = true
                    }
                } catch {
                    diagLog("[Parrot:VAD] Failed, using the full recording: \(error)")
                }
            } else {
                diagLog("[Parrot:VAD] Not ready, skipping silence removal and the short-clip gate")
                services.vad.warmUp()
            }
        }

        if settings.dynamicNormalization {
            audio = AudioNormalizer.normalize(audio)
            changed = true
        }

        if changed {
            session.transcriptionAudio = audio
        }
        return .continue
    }
}

// MARK: - Session Attachments

private enum TranscriptionAudioKey: SessionKey {
    static var defaultValue: [Float]? { nil }
}

private enum SpeechTimeMapKey: SessionKey {
    static var defaultValue: SpeechTimeMap? { nil }
}

private enum SpeechSecondsKey: SessionKey {
    static var defaultValue: TimeInterval? { nil }
}

extension DictationSession {
    /// The audio to transcribe after silence removal and normalization;
    /// nil means `samples` as recorded.
    var transcriptionAudio: [Float]? {
        get { self[TranscriptionAudioKey.self] }
        set { self[TranscriptionAudioKey.self] = newValue }
    }

    /// Maps times in `transcriptionAudio` back to the recording, when
    /// silence was removed.
    var speechTimeMap: SpeechTimeMap? {
        get { self[SpeechTimeMapKey.self] }
        set { self[SpeechTimeMapKey.self] = newValue }
    }

    /// Seconds of speech the detector found; nil when it did not run.
    var speechSeconds: TimeInterval? {
        get { self[SpeechSecondsKey.self] }
        set { self[SpeechSecondsKey.self] = newValue }
    }
}
