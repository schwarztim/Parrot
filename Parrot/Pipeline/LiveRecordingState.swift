import Foundation
import Observation

/// Observable state of the dictation in progress, for the recorder UI and
/// menu bar. One instance lives in `AppServices.live`.
///
/// Every field is declared up front so areas write fields instead of
/// editing this frozen file. Writers: the controller (phase, trigger,
/// modeName, startedAt), participants and stages (the rest).
@MainActor
@Observable
final class LiveRecordingState {
    var phase: DictationPhase = .idle
    var trigger: RecordingTrigger?
    var modeName: String?
    /// Short label of the destination, e.g. "Mail (Subject)". Nil when
    /// destination-aware refinement is off.
    var destinationLabel: String?
    var startedAt: Date?

    /// Recent input levels (0...1) for the waveform.
    var levels: [Float] = []
    /// Name of the device that has delivered only silence, if any.
    var silentMicDevice: String?
    /// Shown when the lid closed and capture moved to another device.
    var lidWarning: String?

    /// Live transcription text that will not change.
    var confirmedText: String = ""
    /// Live transcription text that may still change.
    var hypothesisText: String = ""

    /// Context chips shown in the recorder.
    var selectionChip: String?
    var clipboardChip: String?

    var resultText: String?
    var errorText: String?

    var modeSwitcherShown = false
    var cancelGuardShown = false
    /// 0...1 while stages run, nil when unknown.
    var processingProgress: Double?
}
