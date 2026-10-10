import AppKit
import Foundation

/// Where the controller is in a dictation.
enum DictationPhase: String, Sendable {
    case idle
    /// Participants' `willStart` is running; the mic is not open yet.
    case starting
    case recording
    /// The mic is closing and the stop hooks are running.
    case stopping
    /// Stages are running.
    case processing
}

/// App-level observer for status the views read (today: AppState's
/// `recordingState`, `currentStatus`, `lastTranscription`). Every method
/// defaults to a no-op.
@MainActor
protocol DictationControllerDelegate: AnyObject {
    /// Right before the mic opens (after participants' `willStart`).
    func dictationWillOpenMic(_ session: DictationSession)
    func dictationDidStartRecording(_ session: DictationSession)
    func dictationDidFailToStart(_ session: DictationSession, error: Error)
    /// The mic has closed; the stop hooks have not run yet.
    func dictationDidStopRecording(_ session: DictationSession)
    /// The recording passed the minimum length; stages are about to run.
    func dictationDidBeginProcessing(_ session: DictationSession)
    /// A live session ended: delivered, failed, discarded or cancelled.
    /// Read `session.outcome` and `session.isCancelled`.
    func dictationDidEnd(_ session: DictationSession)
}

extension DictationControllerDelegate {
    func dictationWillOpenMic(_ session: DictationSession) {}
    func dictationDidStartRecording(_ session: DictationSession) {}
    func dictationDidFailToStart(_ session: DictationSession, error: Error) {}
    func dictationDidStopRecording(_ session: DictationSession) {}
    func dictationDidBeginProcessing(_ session: DictationSession) {}
    func dictationDidEnd(_ session: DictationSession) {}
}

/// The one entry point for starting, stopping and cancelling dictation.
/// Hotkeys, `parrot://` URLs, menus, the recorder and the agent all call it.
///
/// Guards (au F9): start is ignored unless idle; stop while starting becomes
/// a pending stop that runs as soon as the mic opens; cancel while starting
/// never opens the mic; cancel while stopping or processing is ignored, as
/// it was before the pipeline existed. Recordings shorter than
/// `minimumDuration` are discarded without running stages.
@MainActor
final class DictationController {

    /// Recordings shorter than this are discarded (too short to transcribe
    /// reliably).
    static let minimumDuration: TimeInterval = 0.3

    let services: AppServices
    let pipeline: DictationPipeline
    weak var delegate: DictationControllerDelegate?

    private(set) var phase: DictationPhase = .idle {
        didSet { services.live.phase = phase }
    }

    /// The live session, from start until it ends.
    private(set) var session: DictationSession?

    /// A stop arrived while starting; it runs once the mic is open.
    private(set) var pendingStop = false

    private let recorderProvider: @MainActor () -> AudioCapturing?
    /// The recorder the live session opened, so stop and cancel close the same one.
    private var activeRecorder: AudioCapturing?

    /// - Parameters:
    ///   - pipeline: Defaults to the production pipeline from `PipelineOrder`.
    ///   - recorder: Supplies the recorder at start. Defaults to
    ///     `services.audioRecorder`; tests pass a fake.
    init(
        services: AppServices,
        pipeline: DictationPipeline? = nil,
        recorder: (@MainActor () -> AudioCapturing?)? = nil
    ) {
        self.services = services
        self.pipeline = pipeline ?? DictationPipeline(services: services)
        self.recorderProvider = recorder ?? { services.audioRecorder as AudioCapturing? }
    }

    // MARK: - Entry Points

    /// Starts a dictation if idle. Returns the task that opens the mic (and
    /// runs a pending stop to the end), or nil when the start is ignored.
    @discardableResult
    func start(trigger: RecordingTrigger, modeOverride: Mode? = nil) -> Task<Void, Never>? {
        diagLog("[Parrot:AppState] startRecording called (phase=\(phase), trigger=\(trigger.rawValue))")
        guard phase == .idle else {
            diagLog("[Parrot:AppState] startRecording BLOCKED: phase is \(phase)")
            return nil
        }
        guard let recorder = recorderProvider() else {
            diagLog("[Parrot:AppState] startRecording BLOCKED: audioRecorder is nil")
            return nil
        }

        let session = DictationSession(trigger: trigger, mode: modeOverride)
        self.session = session
        activeRecorder = recorder
        pendingStop = false
        phase = .starting
        services.live.trigger = trigger
        services.live.startedAt = session.startedAt
        services.live.errorText = nil

        return Task { await open(session, recorder: recorder) }
    }

    /// Stops the recording and runs the stages. Returns the processing task,
    /// or nil when the stop is ignored, deferred, or the recording is discarded.
    @discardableResult
    func stop(trigger: RecordingTrigger) -> Task<Void, Never>? {
        diagLog("[Parrot:AppState] stopRecording called (phase=\(phase), trigger=\(trigger.rawValue))")
        switch phase {
        case .starting:
            diagLog("[Parrot:AppState] Recording is starting, marking for pending stop")
            pendingStop = true
            return nil
        case .recording:
            break
        case .idle, .stopping, .processing:
            return nil
        }
        guard let session, let recorder = activeRecorder else { return nil }

        phase = .stopping
        session.shiftHeldAtStop = NSEvent.modifierFlags.contains(.shift)
        session.samples = recorder.stopRecording()
        delegate?.dictationDidStopRecording(session)
        pipeline.willStop(session)

        let durationSec = session.duration
        diagLog("[Parrot:AppState] Captured \(session.samples.count) samples (\(String(format: "%.1f", durationSec))s)")

        guard !session.samples.isEmpty, durationSec >= Self.minimumDuration else {
            if session.samples.isEmpty {
                diagLog("[Parrot:AppState] No samples captured, skipping transcription")
            } else {
                diagLog("[Parrot:AppState] Recording too short (\(String(format: "%.1f", durationSec))s), skipping transcription")
            }
            session.outcome = .discarded
            pipeline.didFinish(session)
            end(session)
            return nil
        }

        phase = .processing
        delegate?.dictationDidBeginProcessing(session)

        return Task {
            await pipeline.run(session)
            end(session)
        }
    }

    /// Discards the current recording without running stages. Ignored when
    /// idle, stopping or processing.
    func cancel() {
        switch phase {
        case .starting:
            // open() sees this before it opens the mic.
            session?.isCancelled = true
        case .recording:
            guard let session, let recorder = activeRecorder else { return }
            _ = recorder.stopRecording()
            session.isCancelled = true
            pipeline.didCancel(session)
            end(session)
        case .idle, .stopping, .processing:
            break
        }
    }

    /// Starts when idle, stops when starting or recording, otherwise ignored.
    @discardableResult
    func toggle(trigger: RecordingTrigger) -> Task<Void, Never>? {
        switch phase {
        case .idle:
            return start(trigger: trigger)
        case .starting, .recording:
            return stop(trigger: trigger)
        case .stopping, .processing:
            return nil
        }
    }

    /// Runs the stages again on a history entry (for DATA). The stages read
    /// `session.source` to load audio or text. Returns nil when busy.
    func reprocess(historyID: Int64, mode: Mode?) async -> DictationSession? {
        await runOffline(DictationSession(trigger: .menu, mode: mode, source: .reprocess(historyID)))
    }

    /// Runs the stages on an audio file (for ASR.2). The stages read
    /// `session.source` to load the audio. Returns nil when busy.
    func transcribe(file: URL, mode: Mode?) async -> DictationSession? {
        await runOffline(DictationSession(trigger: .menu, mode: mode, source: .file(file)))
    }

    // MARK: - Private

    private func open(_ session: DictationSession, recorder: AudioCapturing) async {
        await pipeline.willStart(session)
        services.live.modeName = session.mode?.name

        if session.isCancelled {
            diagLog("[Parrot:AppState] Cancelled while starting, mic not opened")
            pipeline.didCancel(session)
            reset(session)
            return
        }

        delegate?.dictationWillOpenMic(session)
        do {
            try recorder.startRecording()
        } catch {
            diagLog("[Parrot:AppState] Recording FAILED: \(error)")
            session.outcome = .failed(error.localizedDescription)
            pipeline.didFinish(session)
            reset(session)
            delegate?.dictationDidFailToStart(session, error: error)
            return
        }

        phase = .recording
        delegate?.dictationDidStartRecording(session)
        pipeline.didStart(session)
        diagLog("[Parrot:AppState] Recording STARTED")

        if pendingStop {
            diagLog("[Parrot:AppState] Stop was requested during initialization, stopping now")
            pendingStop = false
            await stop(trigger: session.trigger)?.value
        }
    }

    private func runOffline(_ session: DictationSession) async -> DictationSession? {
        guard phase == .idle else { return nil }
        self.session = session
        phase = .processing
        await pipeline.run(session)
        reset(session)
        return session
    }

    /// Returns to idle and tells the delegate a live session ended.
    private func end(_ session: DictationSession) {
        reset(session)
        delegate?.dictationDidEnd(session)
    }

    private func reset(_ session: DictationSession) {
        if self.session === session {
            self.session = nil
        }
        activeRecorder = nil
        pendingStop = false
        phase = .idle
        services.live.trigger = nil
        services.live.modeName = nil
        services.live.startedAt = nil
    }
}
