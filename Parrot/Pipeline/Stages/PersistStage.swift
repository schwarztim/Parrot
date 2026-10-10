import Foundation

/// Saves the finished dictation to history (DATA).
/// Stub: passes the session through unchanged.
@MainActor
final class PersistStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { true }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        .continue
    }
}
