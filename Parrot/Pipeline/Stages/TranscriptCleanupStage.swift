import Foundation

/// Hallucination and empty-result filtering, literal punctuation (ASR).
/// Stub: passes the session through unchanged.
@MainActor
final class TranscriptCleanupStage: DictationStage {
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
