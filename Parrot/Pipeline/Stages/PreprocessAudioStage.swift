import Foundation

/// Silence removal, short-clip gate and normalization before transcription (ASR).
/// Stub: passes the session through unchanged.
@MainActor
final class PreprocessAudioStage: DictationStage {
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
