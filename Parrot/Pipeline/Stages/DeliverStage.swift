import ApplicationServices
import Foundation

/// Puts the text where it is going: clipboard, then paste or typing (OUT).
///
/// Auto-paste is the mode's override, else the global switch. The user's
/// clipboard is snapshotted first and put back after the restore delay
/// unless the behaviour is replace. Without Accessibility the text stays on
/// the clipboard and the user is told, never a silent failure. With Shift
/// held at stop and auto-submit on, Return follows the paste.
///
/// Sets `session.outcome` and returns `.continue`, so PostActionStage and
/// PersistStage still run. Empty text finishes `.empty`: nothing is pasted
/// or submitted.
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

        let text = session.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagLog("[Parrot:Output] Empty result, nothing to deliver")
            return .finish(.empty)
        }
        services.live.resultText = text

        let output = services.output
        let settings = services.settings?.output

        // File and reprocess runs never type into whatever app is in front:
        // the result only goes on the clipboard.
        guard session.source == .live else {
            output.clipboard.write(text, transient: !(settings?.clipboardHistory ?? false))
            session.outcome = .copiedOnly
            return .continue
        }

        let policy = DeliveryPolicy(
            settings: settings,
            mode: session.mode,
            shiftHeldAtStop: session.shiftHeldAtStop,
            accessibilityTrusted: AXIsProcessTrusted()
        )
        let delivered = (session.outputNeedsLeadingSpace ? " " : "") + text
        let ticket = output.clipboard.write(delivered, transient: policy.markTransient)
        var restoreDelay = policy.restoreDelay
        var pressReturn = policy.pressReturn

        switch policy.method {
        case .clipboardOnly(.autoPasteOff):
            diagLog("[Parrot:Output] Auto-paste off, text left on the clipboard")
            session.outcome = .copiedOnly

        case .clipboardOnly(.untrusted):
            diagLog("[Parrot:Output] Accessibility not granted, text left on the clipboard")
            session.outcome = .copiedOnly
            services.showTransientError(
                "Copied to clipboard. Grant Accessibility to auto-paste (press Cmd+V to paste now)."
            )

        case .type:
            await output.paste.type(delivered)
            session.outcome = .pasted

        case .paste:
            let target = await session.pasteTargetPrefetch?.value
            _ = await output.paste.paste()
            session.outcome = .pasted
            if await output.paste.confirm(target: target) == .unconfirmed {
                // The field reads back unchanged: keep the dictation on the
                // clipboard so it is never lost, and do not submit. Reporting
                // copiedOnly keeps the recorder open with the result and its
                // Copy button instead of closing as if the paste had landed.
                restoreDelay = nil
                pressReturn = false
                session.outcome = .copiedOnly
            }
        }

        if pressReturn {
            diagLog("[Parrot:Output] Auto-submit active (Shift held at stop)")
            await output.paste.pressReturn()
        }
        output.clipboard.finish(ticket, restoreAfter: restoreDelay)
        return .continue
    }
}
