import Foundation

/// Delivery of the final text: clipboard, paste, keystrokes and mode
/// scripts. [OUT]
///
/// DeliverStage and PostActionStage reach these through `services.output`.
/// Tests may replace `clipboard` with one over a fake pasteboard.
/// `start(services:)` runs once at the end of setup.
@MainActor
final class OutputService {
    /// Snapshot, write and restore of the general pasteboard.
    var clipboard: ClipboardService
    /// The serialized paste, typing and Return queue.
    var paste: PasteEngine
    /// Runs per-mode AppleScript after delivery.
    var scripts = AppleScriptRunner()

    init() {
        clipboard = ClipboardService(pasteboard: SystemPasteboard(), scheduler: TaskDelayScheduler())
        paste = PasteEngine(muter: AlertMuter(control: AppleScriptAlertVolume(), scheduler: TaskDelayScheduler()))
    }

    func start(services: AppServices) {}
}
