import Foundation

/// Start, stop and no-result sound cues (AUD).
/// Stub: every hook is the default no-op.
@MainActor
final class SoundCueParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
