import Foundation

/// Shows and hides the recorder window. AppState presents it through
/// `RecordingOverlayPanel`; tests pass a fake.
@MainActor
protocol RecorderUIPresenting: AnyObject {
    /// A session is starting: make sure the recorder is up.
    func showRecorder()
    /// The session ended and nothing should linger: take the recorder down.
    func hideRecorder()
}

/// Drives the recorder around a recording (UI).
///
/// It writes the recorder's fields in `LiveRecordingState` and calls the
/// presenter; the recorder window renders those fields through
/// `RecorderViewModel.reduce`, so a result or error can stay on screen after
/// the controller is back to idle.
@MainActor
final class RecorderUIParticipant: RecordingParticipant {
    private let services: AppServices
    /// Seconds an error stays before it clears itself (tests shorten it).
    var errorDismissDelay = RecorderViewModel.errorDismissDelay

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        let live = services.live
        // A new recording replaces whatever the last one left on screen.
        live.resultText = nil
        live.errorText = nil
        live.cancelGuardShown = false
        live.modeSwitcherShown = false
        live.confirmedText = ""
        live.hypothesisText = ""
        live.levels = []
        live.processingProgress = nil
        services.recorderUI?.showRecorder()
    }

    func willStop(_ session: DictationSession) {
        // The mic is closed; there is nothing left to discard.
        services.live.cancelGuardShown = false
    }

    func didFinish(_ session: DictationSession) {
        let live = services.live
        live.cancelGuardShown = false
        live.modeSwitcherShown = false

        let ending = RecorderViewModel.ending(
            outcome: session.outcome,
            isCancelled: session.isCancelled,
            text: session.text,
            closeAfterResult: services.settings?.recorder.closeAfterResult ?? false
        )
        switch ending {
        case .close:
            live.resultText = nil
            live.errorText = nil
            services.recorderUI?.hideRecorder()
        case .showResult(let text):
            live.errorText = nil
            live.resultText = text
        case .showError(let message):
            live.resultText = nil
            live.errorText = message
            dismissError(message, after: errorDismissDelay)
        }
    }

    func didCancel(_ session: DictationSession) {
        let live = services.live
        live.cancelGuardShown = false
        live.modeSwitcherShown = false
        live.resultText = nil
        live.errorText = nil
        services.recorderUI?.hideRecorder()
    }

    /// Clears the error after `delay` unless a newer session or message
    /// replaced it.
    private func dismissError(_ message: String, after delay: TimeInterval) {
        let live = services.live
        Task { @MainActor [weak live] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let live, live.phase == .idle, live.errorText == message else { return }
            live.errorText = nil
        }
    }
}
