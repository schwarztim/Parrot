import Foundation

/// Agent session hooks around a recording (AGT).
///
/// Latches agent mode when the recording starts: a live recording started
/// while an agent waits and its panel shows is an agent recording, even if
/// that changes before it stops. `AgentRouteStage` reads the flag.
@MainActor
final class AgentParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        session.isAgent = session.source == .live && services.agent.isAcceptingDictation
    }
}
