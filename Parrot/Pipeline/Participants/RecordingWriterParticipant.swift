import Foundation

/// Writes each recording to its own folder on disk (AUD).
/// Stub: every hook is the default no-op.
@MainActor
final class RecordingWriterParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
