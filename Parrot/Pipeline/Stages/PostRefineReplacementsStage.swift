import Foundation

/// Vocabulary replacements applied again after refinement (DATA).
///
/// Runs only when the language model produced text, since it may bring an
/// original word back. Replacements whose text contains their own original
/// are skipped here so they never double. Whole-word matching, as before.
@MainActor
final class PostRefineReplacementsStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        guard session.llmText != nil else { return .continue }
        session.text = services.vocabulary.applyAfterRefinement(to: session.text)
        return .continue
    }
}
