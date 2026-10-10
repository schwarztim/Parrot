import Foundation

// MARK: - Stages

/// What a stage tells the pipeline after it runs.
enum StageResult: Equatable, Sendable {
    /// Hand the session to the next stage.
    case `continue`
    /// End the dictation now with this outcome. Remaining stages are skipped
    /// except those with `runsAfterFinish`.
    case finish(DictationOutcome)
}

/// What the pipeline does when a stage throws.
enum StageFailurePolicy: Sendable {
    /// End the dictation with outcome `.failed`.
    case abort
    /// Restore the text from before the stage, record a warning, toast, and
    /// continue with the next stage.
    case skip
}

/// One step after the mic closes, run in `PipelineOrder.stages` order.
///
/// Stages run on the main actor. Heavy work awaits actors or nonisolated
/// async code, so the main thread is never blocked.
@MainActor
protocol DictationStage: AnyObject {
    init(services: AppServices)
    /// Name used for `session.timings` and warnings.
    var name: String { get }
    var failurePolicy: StageFailurePolicy { get }
    /// Still runs after an earlier stage finished the session (not after a cancel).
    var runsAfterFinish: Bool { get }
    func run(_ session: DictationSession) async throws -> StageResult
}

extension DictationStage {
    var name: String { String(describing: type(of: self)) }
}

// MARK: - Participants

/// Something that reacts to a dictation's lifecycle around the recording
/// (UI, context capture, sounds, playback, writers). Every hook defaults to
/// a no-op, so a participant implements only what it needs.
///
/// Order per session: `willStart`, then (if the mic opened) `didStart`, then
/// `willStop` once the mic has closed, then exactly one of `didFinish` or
/// `didCancel`. A session that fails to open the mic gets `didFinish` with
/// outcome `.failed` and no `didStart`.
@MainActor
protocol RecordingParticipant: AnyObject {
    init(services: AppServices)
    /// Before the mic opens. Awaited; keep it short.
    func willStart(_ session: DictationSession) async
    /// The mic is open and recording.
    func didStart(_ session: DictationSession)
    /// The mic has just closed; stages have not run yet.
    func willStop(_ session: DictationSession)
    /// The session ended; read `session.outcome`.
    func didFinish(_ session: DictationSession)
    /// The user cancelled; nothing is delivered.
    func didCancel(_ session: DictationSession)
}

extension RecordingParticipant {
    func willStart(_ session: DictationSession) async {}
    func didStart(_ session: DictationSession) {}
    func willStop(_ session: DictationSession) {}
    func didFinish(_ session: DictationSession) {}
    func didCancel(_ session: DictationSession) {}
}

// MARK: - Audio Frames

/// A chunk of captured audio: 16 kHz mono Float32.
struct AudioFrame: Sendable {
    static let sampleRate: Double = 16_000

    let samples: [Float]
    /// Index of the first sample, counted from the start of the recording.
    let startSample: Int
}

/// Receives every captured buffer while recording (WAV writer, levels, VAD,
/// live ASR). Register with `AudioRecorder.addSink(_:)`.
///
/// `consume` runs on the audio thread: return quickly, never block, and hop
/// to the main actor yourself for UI work.
protocol AudioFrameSink: AnyObject, Sendable {
    func consume(_ frame: AudioFrame)
}

// MARK: - Capture

/// The part of `AudioRecorder` the controller drives, so tests can pass a
/// fake recorder.
protocol AudioCapturing: AnyObject {
    func startRecording() throws
    func stopRecording() -> [Float]
    /// True when the last recording hit the length cap.
    var didReachCapacity: Bool { get }
}
