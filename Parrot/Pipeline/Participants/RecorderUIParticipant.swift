import Foundation

/// Shows and hides the recorder window. AppState presents today's overlay
/// panel; UI may replace the presenter.
@MainActor
protocol RecorderUIPresenting: AnyObject {
    func showRecorder()
    func hideRecorder()
}

/// Shows and hides the recorder UI around a recording (UI).
/// Stub: every hook is the default no-op.
@MainActor
final class RecorderUIParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
