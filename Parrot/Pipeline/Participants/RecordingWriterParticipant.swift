import Foundation

/// The writer and flush timer of one recording.
private final class RecordingWrite {
    let writer: WavStreamWriter
    let folder: URL
    var timer: DispatchSourceTimer?
    var systemAudio: SystemAudioCapture?
    var reportedWriteError = false

    init(writer: WavStreamWriter, folder: URL) {
        self.writer = writer
        self.folder = folder
    }
}

private enum RecordingWriteKey: SessionKey {
    static let defaultValue: RecordingWrite? = nil
}

private extension DictationSession {
    var recordingWrite: RecordingWrite? {
        get { self[RecordingWriteKey.self] }
        set { self[RecordingWriteKey.self] = newValue }
    }
}

/// Writes each live recording to `recordings/<unix-seconds>/output.wav`
/// (au F11): 16-bit 16 kHz mono, flushed every 15 s so a crash keeps the
/// audio, finalized when the mic closes. Sets `session.recordingFolder`;
/// DATA writes `meta.json` beside it. Also starts system audio capture for
/// modes that record it, so the mix lands in the file. (AUD)
@MainActor
final class RecordingWriterParticipant: RecordingParticipant {
    static let flushInterval: TimeInterval = 15

    static let directoryError = "Could not create recording directory. Please check disk permissions and free space."
    static let writeError = "Failed to write audio data to disk. Please ensure there is enough space and you have write permissions."

    private let services: AppServices
    private let writeQueue = DispatchQueue(label: "com.parrot.recording-writer", qos: .utility)

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        guard session.source == .live, let recorder = services.audioRecorder else { return }

        let folder: URL
        let writer: WavStreamWriter
        do {
            folder = try makeFolder(startedAt: session.startedAt)
            writer = try WavStreamWriter(url: services.paths.recordingAudio(in: folder))
        } catch {
            diagLog("[Parrot:Recording] Could not create the recording folder: \(error)")
            services.showTransientError(Self.directoryError)
            return
        }

        let write = RecordingWrite(writer: writer, folder: folder)
        session.recordingWrite = write
        session.recordingFolder = folder
        recorder.addSink(writer)
        startFlushTimer(for: write)

        if session.mode?.useSystemAudio == true {
            startSystemAudio(for: write, recorder: recorder)
        }
    }

    /// The mic has closed: write the rest and close the file.
    func willStop(_ session: DictationSession) {
        finish(session, keepFolder: true)
    }

    /// Covers a start that failed before the mic opened (no `willStop`).
    func didFinish(_ session: DictationSession) {
        finish(session, keepFolder: true)
    }

    /// A cancelled recording is discarded, folder and all.
    func didCancel(_ session: DictationSession) {
        finish(session, keepFolder: false)
    }

    // MARK: - Private

    /// The folder for this start time, moved a second later while a
    /// recording already holds that name (two starts within one second).
    private func makeFolder(startedAt: Date) throws -> URL {
        var start = startedAt
        var folder = services.paths.recordingFolder(startedAt: start)
        while FileManager.default.fileExists(atPath: services.paths.recordingAudio(in: folder).path) {
            start = start.addingTimeInterval(1)
            folder = services.paths.recordingFolder(startedAt: start)
        }
        return try services.paths.ensureDirectory(folder)
    }

    private func startFlushTimer(for write: RecordingWrite) {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self, weak write] in
            guard let write else { return }
            do {
                try write.writer.flush()
            } catch {
                diagLog("[Parrot:Recording] Flush failed: \(error)")
                Task { @MainActor in self?.reportWriteError(write) }
            }
        }
        timer.resume()
        write.timer = timer
    }

    private func reportWriteError(_ write: RecordingWrite) {
        guard !write.reportedWriteError else { return }
        write.reportedWriteError = true
        services.showTransientError(Self.writeError)
    }

    private func startSystemAudio(for write: RecordingWrite, recorder: AudioRecorder) {
        let capture = SystemAudioCapture()
        write.systemAudio = capture
        recorder.setMixSource(capture)
        let services = services
        Task { @MainActor in
            do {
                try await capture.start()
            } catch {
                diagLog("[Parrot:Recording] System audio capture failed: \(error)")
                recorder.setMixSource(nil)
                services.showTransientError(error.localizedDescription)
            }
        }
    }

    private func finish(_ session: DictationSession, keepFolder: Bool) {
        guard let write = session.recordingWrite else { return }
        session.recordingWrite = nil

        write.timer?.cancel()
        write.timer = nil
        services.audioRecorder?.removeSink(write.writer)
        if let capture = write.systemAudio {
            services.audioRecorder?.setMixSource(nil)
            Task { await capture.stop() }
        }

        let writer = write.writer
        do {
            try writeQueue.sync { try writer.finish() }
        } catch {
            diagLog("[Parrot:Recording] Finalize failed: \(error)")
            reportWriteError(write)
        }

        // Nothing captured (start failed) or cancelled: leave no folder behind.
        if !keepFolder || writer.samplesWritten == 0 {
            try? FileManager.default.removeItem(at: write.folder)
            if session.recordingFolder == write.folder {
                session.recordingFolder = nil
            }
        } else {
            diagLog("[Parrot:Recording] Saved \(writer.samplesWritten) samples to \(write.folder.lastPathComponent)/output.wav")
        }
    }
}
