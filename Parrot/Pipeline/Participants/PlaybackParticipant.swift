import Foundation

/// Pauses or ducks media playback while recording (AUD).
/// Stub: every hook is the default no-op.
@MainActor
final class PlaybackParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
