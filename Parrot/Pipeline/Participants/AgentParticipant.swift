import Foundation

/// Agent session hooks around a recording (AGT).
/// Stub: every hook is the default no-op.
@MainActor
final class AgentParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
