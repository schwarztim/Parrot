import Foundation

// MARK: - Session Value Types

/// What started a dictation. Stages and participants may branch on it (for
/// example, OUT presses Return only for some triggers).
enum RecordingTrigger: String, Sendable, CaseIterable {
    case toggle
    case pushToTalk
    case clickToTalk
    case modeShortcut
    case url
    case menu
    case mini
    case agent
}

/// Where a session's audio comes from.
enum DictationSource: Equatable, Sendable {
    /// Captured from the microphone by the controller.
    case live
    /// An audio or video file (ASR.2 `DictationController.transcribe(file:mode:)`).
    case file(URL)
    /// A history entry run again (DATA `DictationController.reprocess(historyID:mode:)`).
    case reprocess(Int64)
}

/// How a session ended. Set by a stage (or the controller for discards and
/// start failures) and read by participants in `didFinish`.
enum DictationOutcome: Equatable, Sendable {
    case pasted
    case copiedOnly
    case empty
    case discarded
    case routedToAgent
    /// The message is the error's localized description.
    case failed(String)
}

/// One timed piece of a transcript.
struct TranscriptSegment: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float?
    var speaker: String?

    init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speaker = speaker
    }
}

// MARK: - DictationSession

/// Everything one dictation carries from start to finish.
///
/// Every field another area needs is declared here up front, so workstreams
/// fill fields instead of editing this frozen file. Per-area private state
/// goes in the typed attachment bag (see `SessionKey`).
@MainActor
final class DictationSession {

    // MARK: Identity

    let id = UUID()
    let startedAt = Date()
    let trigger: RecordingTrigger
    let source: DictationSource

    // MARK: Inputs (frozen at start)

    /// The mode for this dictation. An override from the controller, or the
    /// mode resolved for the destination in `ContextCaptureParticipant`.
    var mode: Mode?
    /// Destination snapshot captured before the mic opens.
    var context: DictationContext?
    /// Per-recording folder (AUD fills it; nil until then).
    var recordingFolder: URL?
    var deviceName: String?
    /// 16 kHz mono Float32 audio, filled when the mic closes.
    var samples: [Float] = []

    // MARK: Transcript

    /// Transcript exactly as the recognizer returned it.
    var rawTranscript: String = ""
    var segments: [TranscriptSegment] = []
    var speakers: [String] = []
    var language: String?

    // MARK: Working Text

    /// The working copy each stage reads and rewrites; what gets delivered.
    var text: String = ""
    /// The language model's output, when refinement ran and succeeded.
    var llmText: String?
    /// The refinement prompt as rendered at start (LLM).
    var renderedPrompt: String?

    // MARK: Flags

    /// Shift was held when the stop request arrived (latched by the controller).
    var shiftHeldAtStop = false
    /// Refine this dictation even when refinement is off globally.
    var forceRefinement = false
    var isAgent = false
    /// Set by `DictationController.cancel()` (or a stage). The pipeline stops
    /// at the next stage boundary and skips `runsAfterFinish` stages.
    var isCancelled = false

    // MARK: Results

    /// Seconds spent in each stage, keyed by stage name.
    var timings: [String: TimeInterval] = [:]
    /// Non-fatal problems, for example a `.skip` stage that threw.
    var warnings: [String] = []
    var outcome: DictationOutcome?

    // MARK: Attachments

    /// Typed per-area storage. Use `session[MyKey.self]`, not this directly.
    let attachments = SessionAttachments()

    init(trigger: RecordingTrigger, mode: Mode? = nil, source: DictationSource = .live) {
        self.trigger = trigger
        self.mode = mode
        self.source = source
    }

    /// Seconds of captured audio.
    var duration: TimeInterval {
        Double(samples.count) / AudioFrame.sampleRate
    }
}
