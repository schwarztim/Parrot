import Foundation

/// Live text while recording, from the audio frame sinks (ASR).
/// Stub: every hook is the default no-op.
@MainActor
final class LiveTranscriptionParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
