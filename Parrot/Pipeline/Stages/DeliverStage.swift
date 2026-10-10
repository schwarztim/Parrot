import Foundation

/// Puts the text where it is going: clipboard and paste (OUT).
///
/// Copies to the pasteboard and pastes; the text stays on the clipboard
/// afterwards. If Accessibility is missing the paste is skipped and the
/// user is told, never a silent failure.
@MainActor
final class DeliverStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .abort }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        diagLog("[Parrot:AppState] Transcription complete (\(session.text.count) chars)")

        let pasted = await TextInserter.insertText(session.text)
        diagLog("[Parrot:AppState] Text inserted, pasted=\(pasted)")
        session.outcome = pasted ? .pasted : .copiedOnly
        if !pasted {
            services.showTransientError(
                "Copied to clipboard. Grant Accessibility to auto-paste (press Cmd+V to paste now)."
            )
        }
        return .continue
    }
}
