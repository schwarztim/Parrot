import Foundation

/// Saves the finished dictation to history (DATA).
///
/// Writes `meta.json` beside the recording's audio and indexes it (see
/// `RecordingStore.save`). Only delivered dictations are saved, never for
/// secure fields, never when history is off (the recording folder is
/// removed then), and never for reprocess runs.
@MainActor
final class PersistStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { true }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        services.recordings.save(session, services: services)
        return .continue
    }
}
