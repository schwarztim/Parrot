import Foundation

/// Language model refinement of the working text (LLM).
///
/// Runs when `RefinementGate` says so (refinement on, forced, or a mode
/// with its own model; never Voice). Fills the transcript into the prompt
/// rendered at recording start, renders it again when the user switched
/// modes mid-recording, or renders one now for file and reprocess runs.
/// Any failure (missing model, auth, network, a cut-short reply,
/// cancellation) keeps the unrefined text and shows a toast; dictation is
/// never lost.
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
              RefinementGate.shouldRefine(mode: session.mode, settings: settings, forced: session.forceRefinement)
        else { return .continue }

        let transcript = session.text
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .continue }

        let mode = session.mode ?? services.modes?.selectedMode ?? Mode.defaultMode
        let prompt = basePrompt(for: mode, session: session, settings: settings).filled(with: transcript)
        session.renderedPrompt = prompt.fullText
        let request = RefinementRequest(system: prompt.system, user: prompt.user, languageModelID: mode.languageModelID)

        do {
            let refined = try await services.refiner.refine(request, settings: settings)
            guard !session.isCancelled else { return .continue }
            session.text = refined
            session.llmText = refined
        } catch {
            guard !session.isCancelled else { return .continue }
            diagLog("[Parrot:AppState] Refinement FAILED, pasting raw transcript: \(RefinementFallback.logDescription(error))")
            services.showTransientError(RefinementFallback.message(for: error))
        }
        return .continue
    }

    /// The prompt rendered at recording start, unless the user switched to
    /// another mode since: then it is rendered again for `mode`, with the
    /// destination captured at start. File and reprocess runs render one
    /// here from what was saved.
    private func basePrompt(for mode: Mode, session: DictationSession, settings: AppSettings) -> RenderedPrompt {
        if let prompt = session.prompt, session.promptMode == nil || session.promptMode == mode {
            return prompt
        }
        guard session.source == .live, let destination = session.context else {
            return Self.render(mode: mode, destination: session.context, settings: settings)
        }
        let context = services.context.promptContext(for: mode, destination: destination, settings: settings)
        let prompt = PromptRenderer.render(mode: mode, context: context)
        session.prompt = prompt
        session.promptMode = mode
        return prompt
    }

    /// A prompt for a session that had no recording start (a file or a
    /// history entry): the mode and whatever destination was saved, no live
    /// clipboard, system or identity details.
    static func render(mode: Mode, destination: DictationContext?, settings: AppSettings) -> RenderedPrompt {
        let refinement = settings.refinement
        let isLocal = LanguageModelCatalog.isLocal(mode.languageModelID, settings: settings)
        let policy = ContextPolicy(
            sendsContext: refinement.destinationAwareRefinement,
            redactsUserText: !isLocal && refinement.contextLocalOnly,
            includesIdentity: false
        )
        let context = PromptContext.build(mode: mode, destination: destination, policy: policy)
        return PromptRenderer.render(mode: mode, context: context)
    }
}

/// What the toast says when refinement fails and the raw transcript is used.
enum RefinementFallback {

    static func message(for error: Error) -> String {
        let suffix = "Pasted the raw transcript."
        if error is CancellationError {
            return "Refinement was cancelled. \(suffix)"
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return "Refinement was cancelled. \(suffix)" }
            if urlError.code == .timedOut { return "The language model took too long to answer. \(suffix)" }
            return "Could not reach the language model. \(suffix)"
        }
        if let refinement = error as? RefinementError {
            switch refinement {
            case .modelNotFound:
                return "This mode's language model was not found. \(suffix)"
            case .notConfigured:
                return "The language model is not set up. Add its key in Language Models. \(suffix)"
            case .truncated:
                return "The language model ran out of room and cut its answer short. \(suffix)"
            case .providerError(let status, _) where status == 401 || status == 403:
                return "The language model rejected the API key. \(suffix)"
            case .providerError(let status, _) where status == 429:
                return "The language model is busy or over its limit. \(suffix)"
            default:
                break
            }
        }
        return "Refinement failed, pasted raw transcript. \(error.localizedDescription)"
    }

    /// For the log. Auth failures omit the provider's message, which can
    /// quote part of the key.
    static func logDescription(_ error: Error) -> String {
        if case RefinementError.providerError(let status, _) = error, status == 401 || status == 403 {
            return "HTTP \(status) (authentication)"
        }
        return String(describing: error)
    }
}
