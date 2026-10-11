import Foundation

/// Runs one session's participants and stages.
///
/// Built once from `PipelineOrder`. Stages run in order; each returns
/// `.continue` or `.finish(outcome)`, and a throw applies the stage's
/// `failurePolicy`. Each stage's wall time lands in `session.timings`.
/// After an early finish only `runsAfterFinish` stages run, and after a
/// cancel nothing more runs. Participants get exactly one of `didFinish`
/// or `didCancel` per run.
@MainActor
final class DictationPipeline {

    let stages: [any DictationStage]
    let participants: [any RecordingParticipant]

    /// Shows a `.skip` stage's error to the user.
    private let showWarning: @MainActor (String) -> Void

    /// The production pipeline: every participant and stage from
    /// `PipelineOrder`, each created once with the shared services.
    convenience init(services: AppServices) {
        self.init(
            stages: PipelineOrder.stages.map { $0.init(services: services) },
            participants: PipelineOrder.participants.map { $0.init(services: services) },
            showWarning: { [weak services] message in services?.showTransientError(message) }
        )
    }

    init(
        stages: [any DictationStage],
        participants: [any RecordingParticipant],
        showWarning: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.stages = stages
        self.participants = participants
        self.showWarning = showWarning
    }

    // MARK: - Participant Hooks

    func willStart(_ session: DictationSession) async {
        for participant in participants {
            await participant.willStart(session)
        }
    }

    func didStart(_ session: DictationSession) {
        participants.forEach { $0.didStart(session) }
    }

    func willStop(_ session: DictationSession) {
        participants.forEach { $0.willStop(session) }
    }

    func didFinish(_ session: DictationSession) {
        participants.forEach { $0.didFinish(session) }
    }

    func didCancel(_ session: DictationSession) {
        participants.forEach { $0.didCancel(session) }
    }

    // MARK: - Stages

    /// Runs the stages on a session whose audio is ready, then notifies
    /// participants.
    func run(_ session: DictationSession) async {
        // An outcome is set; from here only runsAfterFinish stages run.
        var finished = false
        // didFinish or didCancel has gone out.
        var notified = false

        func finish(with outcome: DictationOutcome) {
            session.outcome = outcome
            finished = true
            if !session.isCancelled {
                notified = true
                didFinish(session)
            }
        }

        for stage in stages {
            if session.isCancelled { break }
            if finished && !stage.runsAfterFinish { continue }

            let textBefore = session.text
            let started = Date()
            do {
                let result = try await stage.run(session)
                if case .finish(let outcome) = result, !finished {
                    finish(with: outcome)
                }
            } catch {
                diagLog("[Parrot:Pipeline] \(stage.name) threw: \(error)")
                if stage.failurePolicy == .abort && !finished {
                    finish(with: .failed(error.localizedDescription))
                } else {
                    session.text = textBefore
                    session.warnings.append("\(stage.name): \(error.localizedDescription)")
                    showWarning(error.localizedDescription)
                }
            }
            session.timings[stage.name] = Date().timeIntervalSince(started)
        }

        guard !notified else { return }
        if session.isCancelled {
            didCancel(session)
        } else {
            didFinish(session)
        }
    }
}
