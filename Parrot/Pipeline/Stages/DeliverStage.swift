import Foundation

/// Puts the text where it is going: clipboard and paste (OUT).
/// Stub: passes the session through unchanged.
@MainActor
final class DeliverStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .abort }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        .continue
    }
}
