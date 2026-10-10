import Foundation

/// Live text while recording, from the audio frame sinks (ASR).
///
/// At start it begins loading the dictation's voice model so the final
/// pass does not wait. When the mode has realtime output on and its model
/// streams, a sink on the recorder feeds a live stream that writes
/// `live.confirmedText` and `live.hypothesisText`. Frames that arrive while
/// the model is still loading are kept and fed once the stream opens. The
/// live text is display only: the pasted text always comes from the full
/// batch pass after the mic closes.
@MainActor
final class LiveTranscriptionParticipant: RecordingParticipant {
    private let services: AppServices

    private var sink: LiveFrameSink?
    private var stream: (any LiveTranscriptionStream)?
    private var opening: Task<Void, Never>?
    private var activeSessionID: UUID?
    /// The model kept loaded for the session in progress.
    private var heldModel: VoiceModelInfo?

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        tearDown()
        releaseModel()
        clearLiveText()

        let settings = services.settings
        let mode = session.mode ?? services.modes?.selectedMode
        let router = services.transcription
        let model = router.resolveModel(for: mode, settings: settings)
        // Keep the model loaded through the recording and the final pass.
        router.retain(model)
        heldModel = model
        router.preload(model, settings: settings)

        guard mode?.realtimeOutput == true, model.supportsRealtime, let recorder = services.audioRecorder else {
            return
        }

        // Register before the mic opens so no frame is missed; the sink
        // holds frames until the stream is ready.
        let sink = LiveFrameSink()
        recorder.addSink(sink)
        self.sink = sink
        activeSessionID = session.id

        let sessionID = session.id
        let options = TranscriptionOptions(mode: mode)
        let onUpdate: @Sendable (LiveTranscriptUpdate) -> Void = { [weak self] update in
            Task { @MainActor in self?.show(update, for: sessionID) }
        }
        opening = Task { [weak self] in
            do {
                let stream = try await router.startLiveStream(
                    model, options: options, settings: settings, onUpdate: onUpdate
                )
                guard let self, self.activeSessionID == sessionID, !Task.isCancelled else {
                    await stream.cancel()
                    return
                }
                self.stream = stream
                sink.attach(stream)
            } catch {
                diagLog("[Parrot:Live] Live text unavailable: \(error.localizedDescription)")
            }
        }
    }

    func willStop(_ session: DictationSession) {
        tearDown()
    }

    func didFinish(_ session: DictationSession) {
        tearDown()
        releaseModel()
        clearLiveText()
    }

    func didCancel(_ session: DictationSession) {
        tearDown()
        releaseModel()
        clearLiveText()
    }

    // MARK: - Private

    private func releaseModel() {
        if let heldModel {
            services.transcription.release(heldModel)
        }
        heldModel = nil
    }

    private func show(_ update: LiveTranscriptUpdate, for sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        services.live.confirmedText = update.confirmed
        services.live.hypothesisText = update.hypothesis
    }

    /// Detaches the sink and ends the stream. Its text stays on screen
    /// until the session finishes.
    private func tearDown() {
        activeSessionID = nil
        opening?.cancel()
        opening = nil
        if let sink {
            services.audioRecorder?.removeSink(sink)
            sink.detach()
        }
        sink = nil
        if let stream {
            Task { await stream.cancel() }
        }
        stream = nil
    }

    private func clearLiveText() {
        services.live.confirmedText = ""
        services.live.hypothesisText = ""
    }
}

/// The recorder sink for live text. Holds frames until a stream attaches,
/// then forwards each frame as it arrives. Runs on the audio thread.
final class LiveFrameSink: AudioFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var stream: (any LiveTranscriptionStream)?
    private var detached = false

    func consume(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard !detached else { return }
        if let stream {
            stream.append(frame.samples)
        } else {
            pending.append(contentsOf: frame.samples)
        }
    }

    /// Feeds the held frames, then every new one, to `stream`.
    func attach(_ stream: any LiveTranscriptionStream) {
        lock.lock()
        defer { lock.unlock() }
        guard !detached else { return }
        stream.append(pending)
        pending = []
        self.stream = stream
    }

    /// Stops forwarding and drops held frames.
    func detach() {
        lock.lock()
        defer { lock.unlock() }
        detached = true
        stream = nil
        pending = []
    }
}
