import Foundation

/// Routes the text to a waiting coding agent instead of pasting (AGT).
/// Stub: passes the session through unchanged.
@MainActor
final class AgentRouteStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        .continue
    }
}
