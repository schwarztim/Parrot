import Foundation

/// Captures the destination and resolves the mode before the mic opens (LLM).
/// Stub: every hook is the default no-op.
@MainActor
final class ContextCaptureParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
