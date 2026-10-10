import Foundation

/// Waveform levels and the silent mic warning while recording (AUD).
/// Stub: every hook is the default no-op.
@MainActor
final class LevelMeterParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
