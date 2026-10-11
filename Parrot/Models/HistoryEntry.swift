import Foundation

/// One dictation stored in the history database.
struct HistoryEntry: Identifiable, Equatable, Hashable {
    let id: Int64
    let timestamp: Date
    let rawTranscript: String
    var finalText: String
    let appBundleID: String?
    let modeName: String?

    // MARK: Schema version 2

    /// The language model's output, when refinement ran.
    var llmText: String? = nil
    /// Display name of the app dictated into.
    var appName: String? = nil
    /// The recording folder (Parrot's own, or an imported one referenced in place).
    var folderPath: String? = nil
    /// The audio file, when one exists.
    var audioPath: String? = nil
    /// Seconds of audio.
    var duration: TimeInterval = 0
    /// Seconds the voice model took.
    var processingTime: TimeInterval = 0
    /// Seconds the language model took.
    var llmProcessingTime: TimeInterval = 0
    var voiceModel: String? = nil
    var languageModel: String? = nil
    var language: String? = nil
    var device: String? = nil
    var rawWordCount: Int = 0
    var llmWordCount: Int = 0
    /// Transcribed from a file; excluded from usage stats.
    var fromFile: Bool = false
    /// Unique origin key: `parrot:<folder>` or `superwhisper:<folder>`.
    var sourceKey: String? = nil

    /// True for a recording brought in by the Superwhisper importer.
    var isImported: Bool { sourceKey?.hasPrefix(SourceKey.superwhisperPrefix) == true }

    /// The words counted for stats: the language model's count when it is
    /// non-zero, else the raw count.
    var statsWordCount: Int { llmWordCount > 0 ? llmWordCount : rawWordCount }

    /// True when the language model produced text (the AI tab has content).
    var hasLLMText: Bool { !(llmText ?? "").isEmpty }

    /// Source key prefixes.
    enum SourceKey {
        static let parrotPrefix = "parrot:"
        static let superwhisperPrefix = "superwhisper:"

        static func parrot(folderName: String) -> String { parrotPrefix + folderName }
        static func superwhisper(folderName: String) -> String { superwhisperPrefix + folderName }
    }
}

/// Every field of a row to save. Word counts are computed when nil. [DATA]
struct HistoryRecord: Equatable {
    var timestamp: Date = Date()
    var rawTranscript: String
    var finalText: String
    var llmText: String? = nil
    var appBundleID: String? = nil
    var appName: String? = nil
    var modeName: String? = nil
    var folderPath: String? = nil
    var audioPath: String? = nil
    var duration: TimeInterval = 0
    var processingTime: TimeInterval = 0
    var llmProcessingTime: TimeInterval = 0
    var voiceModel: String? = nil
    var languageModel: String? = nil
    var language: String? = nil
    var device: String? = nil
    var rawWordCount: Int? = nil
    var llmWordCount: Int? = nil
    var fromFile: Bool = false
    var sourceKey: String? = nil
}

/// Word counting shared by history, stats and the importer.
enum WordCounter {
    /// Whitespace-separated tokens that contain a letter or a digit.
    static func count(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}
