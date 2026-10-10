import AppKit

/// Start, stop and no-result sound cues (AUD).
@MainActor
final class SoundCueParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    private var soundsEnabled: Bool {
        services.settings?.soundEffectsEnabled ?? true
    }

    /// Lets the user know recording started.
    func didStart(_ session: DictationSession) {
        if soundsEnabled {
            NSSound(named: "Tink")?.play()
        }
    }

    /// Lets the user know recording stopped. Plays after the mic closes so
    /// the cue is not captured.
    func willStop(_ session: DictationSession) {
        if soundsEnabled {
            NSSound(named: "Pop")?.play()
        }
    }
}
