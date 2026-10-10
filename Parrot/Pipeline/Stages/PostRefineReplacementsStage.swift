import Foundation

/// Vocabulary replacements applied again after refinement (DATA).
/// Stub: passes the session through unchanged.
@MainActor
final class PostRefineReplacementsStage: DictationStage {
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
