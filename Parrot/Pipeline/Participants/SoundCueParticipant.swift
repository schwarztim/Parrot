import Foundation

/// Start, stop and no-result sound cues (AUD).
@MainActor
final class SoundCueParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Lets the user know recording started.
    func didStart(_ session: DictationSession) {
        services.sounds.play(.start, settings: services.settings?.audio)
    }

    /// Lets the user know recording stopped. Plays after the mic closes so
    /// the cue is not captured.
    func willStop(_ session: DictationSession) {
        services.sounds.play(.stop, settings: services.settings?.audio)
    }

    /// A live recording that produced no text plays the no-result cue.
    func didFinish(_ session: DictationSession) {
        guard session.source == .live, let outcome = session.outcome else { return }
        services.sounds.play(.finish(outcome), settings: services.settings?.audio)
    }
}
