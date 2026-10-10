import Foundation

/// Turns `session.samples` into `rawTranscript` and `text` (ASR).
/// Stub: passes the session through unchanged.
@MainActor
final class TranscribeStage: DictationStage {
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
