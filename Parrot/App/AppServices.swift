import Foundation
import Observation

/// The services a dictation uses, in one container handed to every stage
/// and participant through `init(services:)`.
///
/// Slots are filled where AppState creates each service today (most in
/// `setupAsync`), so a slot is nil until then. Adding a service is one
/// line: a `var` slot under its owner's heading.
@MainActor
@Observable
final class AppServices {

    // MARK: - Shared

    /// App settings, wired at launch by ParrotApp.
    var settings: AppSettings?
    /// Observable state of the dictation in progress.
    let live: LiveRecordingState
    /// Shows a non-blocking error toast. AppState also records the message.
    @ObservationIgnored var showTransientError: @MainActor (String) -> Void = { ErrorToastPanel.show($0) }

    // MARK: - UI

    var permissions: PermissionsManager?
    @ObservationIgnored weak var recorderUI: RecorderUIPresenting?

    // MARK: - AUD

    var audioRecorder: AudioRecorder?

    // MARK: - LLM

    var modes: ModeManager?

    // MARK: - OUT

    var textInserter: TextInserter?

    // MARK: - DATA

    var history: HistoryStore?
    let vocabulary: VocabularyManager

    init(vocabulary: VocabularyManager) {
        self.vocabulary = vocabulary
        self.live = LiveRecordingState()
    }
}
