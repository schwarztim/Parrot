import Foundation

/// Vocabulary find and replace on the transcript (DATA).
@MainActor
final class ReplacementsStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        session.text = services.vocabulary.apply(to: session.text)
        return .continue
    }
}
