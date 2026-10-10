import Foundation

private enum PlaybackTokenKey: SessionKey {
    static let defaultValue: MediaControlService.Token? = nil
}

private extension DictationSession {
    var playbackToken: MediaControlService.Token? {
        get { self[PlaybackTokenKey.self] }
        set { self[PlaybackTokenKey.self] = newValue }
    }
}

/// Pauses, lowers or mutes other audio while recording (AUD). The mode's
/// `playbackBehavior` wins over the global default; the fade starts before
/// the mic opens and is never awaited.
@MainActor
final class PlaybackParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        guard session.source == .live else { return }
        let behavior = PlaybackResolution.resolve(
            mode: session.mode?.playbackBehavior,
            global: services.settings?.audio.playbackBehavior ?? .pause
        )
        session.playbackToken = services.media.begin(behavior)
    }

    func willStop(_ session: DictationSession) {
        restore(session)
    }

    /// Covers a start that failed before the mic opened (no `willStop`).
    func didFinish(_ session: DictationSession) {
        restore(session)
    }

    func didCancel(_ session: DictationSession) {
        restore(session)
    }

    private func restore(_ session: DictationSession) {
        guard let token = session.playbackToken else { return }
        session.playbackToken = nil
        services.media.end(token)
    }
}
