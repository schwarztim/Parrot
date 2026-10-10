import Foundation

/// Saves the finished dictation to history (DATA).
///
/// Only delivered dictations are saved, never for secure fields, never when
/// history is off.
@MainActor
final class PersistStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { true }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        guard session.outcome == .pasted || session.outcome == .copiedOnly else { return .continue }

        let context = session.context
        if services.settings?.history.historyEnabled == true, context?.isSecureField != true {
            _ = try? services.history?.insert(
                rawTranscript: session.rawTranscript,
                finalText: session.text,
                appBundleID: context?.bundleID,
                modeName: session.mode?.name
            )
        }
        return .continue
    }
}
