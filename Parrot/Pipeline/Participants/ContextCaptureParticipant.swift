import Foundation

/// Captures the destination and resolves the mode before the mic opens (LLM).
@MainActor
final class ContextCaptureParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Captures the frontmost app and focused field while the target app is
    /// still frontmost, and warms a local refinement model. Capture always
    /// runs (it is cheap, bounded by a 0.1 s AX timeout, and reads nothing
    /// from secure fields) so history and per-app auto-mode have the bundle
    /// id even when destination-aware refinement is off. Only the overlay
    /// label is gated on the setting; refinement gates prompt context itself.
    func willStart(_ session: DictationSession) async {
        let settings = services.settings
        let context = ContextSnapshotter.capture()
        session.context = context
        services.live.destinationLabel = (settings?.refinement.destinationAwareRefinement == true) ? context.displayLabel : nil

        // An app-assigned mode wins, otherwise the selected mode. Applied to
        // this session only; the user's selection never changes.
        if session.mode == nil {
            session.mode = services.modes?.resolveMode(context: context)
        }
        diagLog("[Parrot:AppState] Destination: \(context.displayLabel ?? "unknown"), secure=\(context.isSecureField), mode=\(session.mode?.name ?? "-")")

        // Costs no perceived latency: runs before the user finishes speaking.
        if let settings { services.refiner.warmUpIfLocal(settings: settings) }
    }

    func didFinish(_ session: DictationSession) {
        services.live.destinationLabel = nil
    }

    func didCancel(_ session: DictationSession) {
        services.live.destinationLabel = nil
    }
}
