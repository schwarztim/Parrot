import Foundation

/// Final formatting before delivery, such as autocapitalization (OUT).
/// Stub: passes the session through unchanged.
@MainActor
final class FormatOutputStage: DictationStage {
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
