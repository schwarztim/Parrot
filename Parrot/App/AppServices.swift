import Foundation
import Observation

/// The services a dictation uses, in one container handed to every stage
/// and participant through `init(services:)`. Frozen.
///
/// Optional slots are filled where AppState creates each service today
/// (most in `setupAsync`), so they are nil until then. The other slots
/// exist from init. Every service has its slot here already; its owner
/// grows the class in its own file. `startServices()` runs once at the end
/// of setup and calls each owner's `start(services:)`.
@MainActor
@Observable
final class AppServices {

    // MARK: - Shared

    /// App settings, wired at launch by ParrotApp.
    var settings: AppSettings?
    /// Observable state of the dictation in progress.
    let live: LiveRecordingState
    /// Where Parrot keeps its files. Tests point it at a temporary root.
    var paths = AppPaths()
    /// Shows a non-blocking error toast. AppState also records the message.
    @ObservationIgnored var showTransientError: @MainActor (String) -> Void = { ErrorToastPanel.show($0) }

    // MARK: - UI

    var permissions: PermissionsManager?
    @ObservationIgnored weak var recorderUI: RecorderUIPresenting?

    // MARK: - AUD

    var audioRecorder: AudioRecorder?
    var devices = AudioDeviceService()
    var media = MediaControlService()
    var sounds = SoundService()

    // MARK: - ASR

    /// The on-device engine, its preparation and readiness.
    let transcription: TranscriptionRouter
    var vad = VoiceActivityService()
    var voiceCatalog = VoiceModelCatalog()

    // MARK: - LLM

    var modes: ModeManager?
    var refiner: any Refiner = ConfiguredRefiner()
    var context = ContextService()

    // MARK: - OUT

    var textInserter: TextInserter?
    var output = OutputService()

    // MARK: - TRG

    /// The global hotkey listener and binding conversion.
    let hotkeys: HotkeyCenter

    // MARK: - DATA

    var history: HistoryStore?
    var recordings = RecordingStore()
    let vocabulary: VocabularyManager
    /// Usage stats. DATA assigns its real service here.
    var stats: any StatsService = ZeroStatsService()

    // MARK: - AGT

    var agent = AgentBridge()

    init(vocabulary: VocabularyManager) {
        self.vocabulary = vocabulary
        self.live = LiveRecordingState()
        self.transcription = TranscriptionRouter(vocabulary: vocabulary)
        self.hotkeys = HotkeyCenter()
    }

    /// Starts every stub-slot service once, after setup has filled the
    /// optional slots. Each `start(services:)` is its owner's to fill.
    func startServices() {
        devices.start(services: self)
        media.start(services: self)
        sounds.start(services: self)
        vad.start(services: self)
        voiceCatalog.start(services: self)
        context.start(services: self)
        output.start(services: self)
        recordings.start(services: self)
        agent.start(services: self)
    }
}
