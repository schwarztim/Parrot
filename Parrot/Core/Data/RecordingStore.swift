import AVFoundation
import Foundation

/// Recording folders on disk (`AppPaths.recordings`) and their `meta.json`.
/// [DATA]
///
/// PersistStage calls `save(_:services:)` to write `meta.json` beside AUD's
/// `output.wav` and index the recording. At launch `start(services:)`
/// registers the stats service, reconciles the folders with the history
/// index, applies retention, and schedules retention once a day.
@MainActor
final class RecordingStore {

    /// What a launch reconciliation found. Logged, and returned for tests.
    struct ReconcileReport: Equatable {
        /// Recording folders seen on disk.
        var scanned = 0
        /// Folders added to the index.
        var inserted = 0
        /// Folders already indexed.
        var alreadyIndexed = 0
        /// `meta.json` present but unreadable: skipped.
        var corrupt = 0
        /// `output.wav` and no `meta.json` (a discarded or empty recording): ignored.
        var audioOnly = 0
        /// Neither file: ignored.
        var empty = 0
        /// Index rows whose folder is gone: dropped.
        var orphansRemoved = 0
    }

    /// Seconds between retention passes after launch.
    static let retentionInterval: TimeInterval = 86_400

    private weak var services: AppServices?
    private var retentionTimer: Timer?
    private(set) var lastReconcile: ReconcileReport?

    init() {}

    func start(services: AppServices) {
        self.services = services
        let stats = HistoryStatsService(history: services.history)
        stats.typingWPM = { [weak services] in services?.settings?.history.typingWPM ?? HistorySettings.defaultTypingWPM }
        services.stats = stats

        guard let history = services.history else { return }
        let root = services.paths.recordings
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                Self.reconcile(root: root, history: history)
            }.value
            self?.lastReconcile = report
            self?.applyRetention()
        }

        retentionTimer?.invalidate()
        let timer = Timer(timeInterval: Self.retentionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    /// Deletes recordings older than the retention setting (0 keeps them).
    /// Folders go too, but only Parrot's own.
    @discardableResult
    func applyRetention() -> Int {
        guard let services, let history = services.history,
              let days = services.settings?.history.historyRetentionDays, days > 0
        else { return 0 }
        let deleted = (try? history.pruneOlderThan(days: days)) ?? 0
        if deleted > 0 {
            diagLog("[Parrot:History] Retention deleted \(deleted) recordings older than \(days) days")
        }
        return deleted
    }

    // MARK: - Save

    /// Saves a finished dictation: `meta.json` in its folder plus the index
    /// row. Runs for delivered dictations only. Reprocess runs are never
    /// saved (their result goes to the clipboard). With history off, or for
    /// a secure field, nothing is kept: the recording folder is removed.
    func save(_ session: DictationSession, services: AppServices) {
        if case .reprocess = session.source { return }
        guard let settings = services.settings else { return }

        let secure = session.context?.isSecureField == true
        guard settings.history.historyEnabled, !secure else {
            if let folder = session.recordingFolder {
                RecordingFolders.removeIfOwned(folder, root: services.paths.recordings)
            }
            return
        }
        guard session.outcome == .pasted || session.outcome == .copiedOnly else { return }

        var folder = session.recordingFolder
        var audioPath: String?
        if case .file(let url) = session.source {
            audioPath = url.path
            if folder == nil { folder = try? makeFolder(startedAt: session.startedAt, services: services) }
        } else if let folder {
            let wav = services.paths.recordingAudio(in: folder)
            if FileManager.default.fileExists(atPath: wav.path) { audioPath = wav.path }
        }

        let meta = Self.makeMeta(session, settings: settings, savePromptContext: settings.history.savePromptContext)
        if let folder {
            do {
                try meta.write(to: folder)
            } catch {
                diagLog("[Parrot:History] Could not write meta.json: \(error)")
            }
        }

        do {
            try services.history?.insert(meta.historyRecord(folder: folder, audioPath: audioPath))
        } catch {
            diagLog("[Parrot:History] Could not save to history: \(error)")
        }
    }

    /// A new folder for a recording with no audio folder (file transcription).
    private func makeFolder(startedAt: Date, services: AppServices) throws -> URL {
        var start = startedAt
        var folder = services.paths.recordingFolder(startedAt: start)
        while FileManager.default.fileExists(atPath: folder.path) {
            start = start.addingTimeInterval(1)
            folder = services.paths.recordingFolder(startedAt: start)
        }
        return try services.paths.ensureDirectory(folder)
    }

    /// Builds the metadata for a finished session.
    static func makeMeta(_ session: DictationSession, settings: AppSettings?, savePromptContext: Bool) -> RecordingMeta {
        var meta = RecordingMeta(startedAt: session.startedAt.timeIntervalSince1970.rounded(.down), finalText: session.text)
        meta.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        meta.sessionID = session.id.uuidString
        meta.duration = session.duration
        meta.timings = session.timings
        meta.processingTime = session.timings["TranscribeStage"] ?? 0
        if session.llmText != nil {
            meta.languageModelProcessingTime = session.timings["RefineStage"]
        }
        meta.device = session.deviceName
        meta.trigger = session.trigger.rawValue
        meta.outcome = session.outcome.map(Self.outcomeName)
        meta.language = session.language

        if let mode = session.mode {
            meta.modeName = mode.name
            meta.modeKey = mode.key
            meta.flags = RecordingMeta.Flags(
                translate: mode.translateToEnglish,
                literalPunctuation: mode.literalPunctuation,
                realtime: mode.realtimeOutput,
                diarize: mode.diarize,
                systemAudio: mode.useSystemAudio,
                applicationContext: mode.contextFromActiveApplication
            )
        }
        meta.voiceModel = Self.voiceModelName(mode: session.mode, settings: settings)
        if session.llmText != nil {
            meta.languageModel = Self.languageModelName(mode: session.mode, settings: settings)
        }

        meta.appName = session.context?.appName
        meta.appBundleID = session.context?.bundleID
        if case .file(let url) = session.source {
            meta.fromFile = true
            meta.sourceFile = url.path
        }

        meta.rawText = session.rawTranscript
        meta.llmText = session.llmText
        meta.segments = session.segments
        meta.speakers = session.speakers

        if savePromptContext {
            meta.renderedPrompt = session.renderedPrompt
            if let context = session.context {
                var fields: [String: String] = [:]
                fields["appName"] = context.appName
                fields["bundleID"] = context.bundleID
                fields["fieldRole"] = context.fieldRole
                fields["fieldLabel"] = context.fieldLabel
                fields["selectedText"] = context.selectedText
                fields["textBeforeCursor"] = context.textBeforeCursor
                meta.context = fields.isEmpty ? nil : fields
            }
        }
        return meta
    }

    private static func voiceModelName(mode: Mode?, settings: AppSettings?) -> String? {
        if let id = mode?.voiceModelID, !id.isEmpty { return id }
        return settings?.transcription.transcriptionProvider.displayName
    }

    private static func languageModelName(mode: Mode?, settings: AppSettings?) -> String? {
        if let id = mode?.languageModelID, !id.isEmpty { return id }
        return settings?.refinement.refinementProvider.displayName
    }

    private static func outcomeName(_ outcome: DictationOutcome) -> String {
        switch outcome {
        case .pasted: return "pasted"
        case .copiedOnly: return "copiedOnly"
        case .empty: return "empty"
        case .discarded: return "discarded"
        case .routedToAgent: return "routedToAgent"
        case .failed: return "failed"
        }
    }

    // MARK: - Reconciliation

    /// Makes the index match the folders: inserts folders missing from it,
    /// drops rows whose folder is gone, skips corrupt `meta.json`, and
    /// ignores folders with audio and no `meta.json` (AUD keeps those for
    /// discarded and empty recordings). Only rows keyed `parrot:` are
    /// touched; imported and older rows are left alone.
    nonisolated static func reconcile(root: URL, history: HistoryStore, fileManager: FileManager = .default) -> ReconcileReport {
        var report = ReconcileReport()
        let prefix = HistoryEntry.SourceKey.parrotPrefix

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else {
            // No readable recordings folder: never drop rows on that basis.
            diagLog("[Parrot:History] Reconcile skipped: no recordings folder")
            return report
        }

        let indexed = (try? history.sourceKeys(withPrefix: prefix)) ?? []
        var missing: [HistoryRecord] = []
        for name in names.sorted() where RecordingFolders.isRecordingFolderName(name) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            report.scanned += 1

            let metaURL = folder.appendingPathComponent(RecordingMeta.fileName)
            let wavURL = folder.appendingPathComponent("output.wav")
            guard fileManager.fileExists(atPath: metaURL.path) else {
                if fileManager.fileExists(atPath: wavURL.path) {
                    report.audioOnly += 1
                } else {
                    report.empty += 1
                }
                continue
            }
            if indexed.contains(HistoryEntry.SourceKey.parrot(folderName: name)) {
                report.alreadyIndexed += 1
                continue
            }
            guard let meta = try? RecordingMeta.read(from: folder) else {
                report.corrupt += 1
                continue
            }
            let audio: String?
            if fileManager.fileExists(atPath: wavURL.path) {
                audio = wavURL.path
            } else {
                audio = meta.sourceFile
            }
            missing.append(meta.historyRecord(folder: folder, audioPath: audio))
        }

        if !missing.isEmpty {
            report.inserted = (try? history.importRecords(missing)) ?? 0
        }

        let rows = (try? history.folderRows(sourceKeyPrefix: prefix)) ?? []
        let orphans = rows.filter { row in
            guard let path = row.folderPath else { return false }
            return !fileManager.fileExists(atPath: path)
        }
        if !orphans.isEmpty {
            report.orphansRemoved = (try? history.delete(ids: orphans.map(\.id))) ?? 0
        }

        diagLog("[Parrot:History] Reconcile: \(report.scanned) folders, \(report.inserted) added, \(report.alreadyIndexed) indexed, \(report.corrupt) corrupt, \(report.audioOnly) audio only, \(report.empty) empty, \(report.orphansRemoved) orphans removed")
        return report
    }

    // MARK: - Audio

    /// The 16 kHz mono samples of a history entry's audio, for reprocessing.
    /// Nil when the entry has no readable audio.
    func samples(forHistoryID id: Int64) -> [Float]? {
        guard let entry = try? services?.history?.entry(id: id), let path = entry.audioPath else { return nil }
        return Self.loadSamples(from: URL(fileURLWithPath: path))
    }

    /// What `DictationController.reprocess(historyID:mode:)` needs: the
    /// entry's audio (empty when it has none) and its raw transcript, used
    /// as the text when there is no audio. Nil for an unknown id.
    func reprocessInput(historyID id: Int64) -> (samples: [Float], rawTranscript: String)? {
        guard let entry = try? services?.history?.entry(id: id) else { return nil }
        let samples = entry.audioPath.flatMap { Self.loadSamples(from: URL(fileURLWithPath: $0)) } ?? []
        return (samples, entry.rawTranscript)
    }

    /// Reads any audio file AVFoundation can open as 16 kHz mono Float32:
    /// channels are averaged, other rates resampled linearly. Nil when
    /// unreadable.
    nonisolated static func loadSamples(from url: URL, sampleRate: Double = 16_000) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0
        else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return nil }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        if channelCount > 1 {
            for channel in 1..<channelCount {
                for i in 0..<frames { mono[i] += channels[channel][i] }
            }
            let scale = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
        }

        guard format.sampleRate != sampleRate, format.sampleRate > 0 else { return mono }
        let ratio = format.sampleRate / sampleRate
        let outCount = Int(Double(frames) / ratio)
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let position = Double(i) * ratio
            let index = Int(position)
            let next = min(index + 1, frames - 1)
            let fraction = Float(position - Double(index))
            output[i] = mono[index] * (1 - fraction) + mono[next] * fraction
        }
        return output
    }
}
