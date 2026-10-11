import Foundation

/// Parrot's `meta.json`, written beside `output.wav` in each recording
/// folder. The folder is the source of truth; the history database is an
/// index rebuilt from these files at launch. [DATA]
///
/// The rendered prompt and the captured context are stored only when
/// `parrot.history.savePromptContext` is on.
struct RecordingMeta: Codable, Equatable {

    static let currentVersion = 1
    static let fileName = "meta.json"

    /// Mode flags at record time.
    struct Flags: Codable, Equatable {
        var translate = false
        var literalPunctuation = false
        var realtime = false
        var diarize = false
        var systemAudio = false
        var applicationContext = false
    }

    var version: Int = RecordingMeta.currentVersion
    var appVersion: String?
    var sessionID: String?
    /// Start time in unix seconds.
    var startedAt: Double
    /// Seconds of audio.
    var duration: Double = 0
    /// Seconds the voice model took.
    var processingTime: Double = 0
    /// Seconds the language model took, when it ran.
    var languageModelProcessingTime: Double?
    /// Seconds per pipeline stage.
    var timings: [String: Double] = [:]
    var device: String?
    var trigger: String?
    var outcome: String?
    var modeName: String?
    var modeKey: String?
    var voiceModel: String?
    var languageModel: String?
    var language: String?
    var appName: String?
    var appBundleID: String?
    var fromFile = false
    /// The transcribed file, for a file transcription (referenced, not copied).
    var sourceFile: String?
    var flags = Flags()
    var rawText: String = ""
    var llmText: String?
    var finalText: String
    var segments: [TranscriptSegment] = []
    var speakers: [String] = []
    /// Only with `savePromptContext` on.
    var renderedPrompt: String?
    /// Only with `savePromptContext` on.
    var context: [String: String]?

    init(startedAt: Double, finalText: String) {
        self.startedAt = startedAt
        self.finalText = finalText
    }

    private enum CodingKeys: String, CodingKey {
        case version, appVersion, sessionID, startedAt, duration, processingTime
        case languageModelProcessingTime, timings, device, trigger, outcome
        case modeName, modeKey, voiceModel, languageModel, language, appName, appBundleID
        case fromFile, sourceFile, flags, rawText, llmText, finalText, segments, speakers
        case renderedPrompt, context
    }

    /// Lenient: only `startedAt` and `finalText` are required, so older or
    /// partial files still load. Anything else missing takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Double.self, forKey: .startedAt)
        finalText = try c.decode(String.self, forKey: .finalText)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        processingTime = try c.decodeIfPresent(Double.self, forKey: .processingTime) ?? 0
        languageModelProcessingTime = try c.decodeIfPresent(Double.self, forKey: .languageModelProcessingTime)
        timings = try c.decodeIfPresent([String: Double].self, forKey: .timings) ?? [:]
        device = try c.decodeIfPresent(String.self, forKey: .device)
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        modeName = try c.decodeIfPresent(String.self, forKey: .modeName)
        modeKey = try c.decodeIfPresent(String.self, forKey: .modeKey)
        voiceModel = try c.decodeIfPresent(String.self, forKey: .voiceModel)
        languageModel = try c.decodeIfPresent(String.self, forKey: .languageModel)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        fromFile = try c.decodeIfPresent(Bool.self, forKey: .fromFile) ?? false
        sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile)
        flags = try c.decodeIfPresent(Flags.self, forKey: .flags) ?? Flags()
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        llmText = try c.decodeIfPresent(String.self, forKey: .llmText)
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        renderedPrompt = try c.decodeIfPresent(String.self, forKey: .renderedPrompt)
        context = try c.decodeIfPresent([String: String].self, forKey: .context)
    }

    // MARK: - Files

    /// Pretty, key-sorted JSON written atomically.
    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Reads a folder's `meta.json`. Nil when missing; throws when corrupt.
    static func read(from folder: URL) throws -> RecordingMeta? {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RecordingMeta.self, from: data)
    }

    // MARK: - History Row

    /// The history row for this recording. `audioPath` is the WAV when one
    /// exists (or the source file of a file transcription).
    func historyRecord(folder: URL?, audioPath: String?) -> HistoryRecord {
        HistoryRecord(
            timestamp: Date(timeIntervalSince1970: startedAt),
            rawTranscript: rawText,
            finalText: finalText,
            llmText: llmText,
            appBundleID: appBundleID,
            appName: appName,
            modeName: modeName,
            folderPath: folder?.path,
            audioPath: audioPath,
            duration: duration,
            processingTime: processingTime,
            llmProcessingTime: languageModelProcessingTime ?? 0,
            voiceModel: voiceModel,
            languageModel: languageModel,
            language: language,
            device: device,
            fromFile: fromFile,
            sourceKey: folder.map { HistoryEntry.SourceKey.parrot(folderName: $0.lastPathComponent) }
        )
    }
}
