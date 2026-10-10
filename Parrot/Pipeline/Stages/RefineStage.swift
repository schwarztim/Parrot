import Foundation

/// Language model refinement of the working text (LLM).
///
/// Runs when refinement is on, or forced for this dictation. Any failure
/// keeps the unrefined text and shows a toast; dictation is never lost.
@MainActor
final class RefineStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        guard let settings = services.settings,
              settings.refinement.refinementEnabled || session.forceRefinement
        else { return .continue }

        do {
            let refined = try await services.refiner.refine(
                session.text,
                modePrompt: session.mode?.refinementPrompt,
                context: session.context,
                settings: settings
            )
            session.text = refined
            session.llmText = refined
        } catch {
            diagLog("[Parrot:AppState] Refinement FAILED, pasting raw transcript: \(error)")
            services.showTransientError(
                "Refinement failed, pasted raw transcript. \(error.localizedDescription)"
            )
        }
        return .continue
    }
}
