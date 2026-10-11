import Foundation

/// Routes the text to a waiting coding agent instead of pasting (AGT).
///
/// Only for sessions `AgentParticipant` marked `isAgent` at recording start
/// (an agent was waiting and its panel was showing). The text goes to the
/// panel's pending-send editor, the outcome becomes `.routedToAgent`, and
/// the pipeline finishes, so DeliverStage never pastes it. Empty text
/// finishes `.empty` and leaves the panel as it was. If the agent session
/// went away mid-recording, the text is delivered normally.
@MainActor
final class AgentRouteStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        guard session.isAgent, session.source == .live else { return .continue }
        let text = session.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .finish(.empty)
        }
        guard await services.agent.receiveDictation(text, autoSend: session.shiftHeldAtStop) else {
            return .continue
        }
        diagLog("[Parrot:Agent] Dictation routed to the agent panel (\(text.count) chars)")
        session.outcome = .routedToAgent
        return .finish(.routedToAgent)
    }
}
