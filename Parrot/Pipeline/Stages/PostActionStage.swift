import Foundation

/// Per-mode actions after delivery: the mode's AppleScript (OUT).
///
/// When the mode's script is on, `{{user_message}}` becomes the final text
/// (escaped for an AppleScript string) and the script runs in the
/// background with a timeout, after the paste. A failure shows a toast and
/// never holds up or changes the result.
@MainActor
final class PostActionStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        guard session.source == .live,
              let mode = session.mode, mode.scriptEnabled,
              !mode.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.outcome == .pasted || session.outcome == .copiedOnly
        else { return .continue }

        let source = AppleScriptMacro.render(script: mode.script, userMessage: session.text)
        let runner = services.output.scripts
        let showError = services.showTransientError
        let modeName = mode.name
        Task {
            do {
                _ = try await runner.run(source)
                diagLog("[Parrot:Output] Mode script finished")
            } catch {
                // The error text can quote the script, so it stays out of the log.
                diagLog("[Parrot:Output] Failed to run script")
                showError("The \(modeName) script failed: \(error.localizedDescription)")
            }
        }
        return .continue
    }
}
