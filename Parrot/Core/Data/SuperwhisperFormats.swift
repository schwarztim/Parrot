import Foundation

/// Read-only decoders for Superwhisper's app folder files (spec section 4).
/// [DATA]
///
/// Privacy: the meta.json decoder has no property for `prompt` and reads
/// only `applicationContext.name` out of `promptContext`, so prompts,
/// clipboard text, selected text and screen nouns are never materialized.
enum Superwhisper {

    // MARK: - meta.json

    struct Segment: Decodable, Equatable {
        var text: String
        var start: Double
        var end: Double
        var confidence: Double?
        var speaker: Int?

        private enum CodingKeys: String, CodingKey { case text, start, end, confidence, speaker }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
            start = c.flexibleDouble(.start) ?? 0
            end = c.flexibleDouble(.end) ?? 0
            confidence = c.flexibleDouble(.confidence)
            speaker = c.flexibleDouble(.speaker).map { Int($0) }
        }
    }

    struct Speaker: Decodable, Equatable {
        var name: String?
        var number: Int?

        private enum CodingKeys: String, CodingKey { case name, number }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            number = c.flexibleDouble(.number).map { Int($0) }
        }
    }

    /// One recording's `meta.json`. Durations are milliseconds on disk.
    struct Meta: Decodable, Equatable {
        var datetime: String?
        var appVersion: String?
        var modelKey: String?
        var modelName: String?
        var languageModelKey: String?
        var languageModelName: String?
        /// Milliseconds.
        var duration: Double?
        /// Milliseconds.
        var processingTime: Double?
        /// Milliseconds.
        var languageModelProcessingTime: Double?
        var recordingDevice: String?
        var languageSelected: String?
        var literalPunctuationEnabled: Bool?
        var translationEnabled: Bool?
        var realtimeEnabled: Bool?
        var separateSpeakersEnabled: Bool?
        var systemAudioEnabled: Bool?
        var applicationContextEnabled: Bool?
        var rawResult: String?
        var llmResult: String?
        var result: String?
        var modeName: String?
        var segments: [Segment]
        var speakers: [Speaker]
        /// `promptContext.applicationContext.name`, the only app identifier stored.
        var appName: String?

        private enum CodingKeys: String, CodingKey {
            case datetime, appVersion, modelKey, modelName, languageModelKey, languageModelName
            case duration, processingTime, languageModelProcessingTime, recordingDevice, languageSelected
            case literalPunctuationEnabled, translationEnabled, realtimeEnabled, separateSpeakersEnabled
            case systemAudioEnabled, applicationContextEnabled, rawResult, llmResult, result, modeName
            case segments, speakers, promptContext
        }

        private enum PromptContextKeys: String, CodingKey { case applicationContext }
        private enum ApplicationContextKeys: String, CodingKey { case name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            datetime = c.string(.datetime)
            appVersion = c.string(.appVersion)
            modelKey = c.string(.modelKey)
            modelName = c.string(.modelName)
            languageModelKey = c.string(.languageModelKey)
            languageModelName = c.string(.languageModelName)
            duration = c.flexibleDouble(.duration)
            processingTime = c.flexibleDouble(.processingTime)
            languageModelProcessingTime = c.flexibleDouble(.languageModelProcessingTime)
            recordingDevice = c.string(.recordingDevice)
            languageSelected = c.string(.languageSelected)
            literalPunctuationEnabled = try? c.decodeIfPresent(Bool.self, forKey: .literalPunctuationEnabled)
            translationEnabled = try? c.decodeIfPresent(Bool.self, forKey: .translationEnabled)
            realtimeEnabled = try? c.decodeIfPresent(Bool.self, forKey: .realtimeEnabled)
            separateSpeakersEnabled = try? c.decodeIfPresent(Bool.self, forKey: .separateSpeakersEnabled)
            systemAudioEnabled = try? c.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled)
            applicationContextEnabled = try? c.decodeIfPresent(Bool.self, forKey: .applicationContextEnabled)
            rawResult = c.string(.rawResult)
            llmResult = c.string(.llmResult)
            result = c.string(.result)
            modeName = c.string(.modeName)
            segments = (try? c.decodeIfPresent([Segment].self, forKey: .segments)) ?? []
            speakers = (try? c.decodeIfPresent([Speaker].self, forKey: .speakers)) ?? []

            // Only the app name; nothing else in promptContext is read.
            if let context = try? c.nestedContainer(keyedBy: PromptContextKeys.self, forKey: .promptContext),
               let app = try? context.nestedContainer(keyedBy: ApplicationContextKeys.self, forKey: .applicationContext) {
                appName = try? app.decodeIfPresent(String.self, forKey: .name)
            }
        }

        /// What was delivered: `result`, else `llmResult`, else `rawResult`.
        var finalText: String {
            for text in [result, llmResult, rawResult] {
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return ""
        }

        /// True when both the raw and the final text are empty (no speech).
        var hasNoText: Bool {
            (rawResult ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Speaker names in order.
        var speakerNames: [String] {
            speakers.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
                .map { $0.name ?? "Speaker \(($0.number ?? 0) + 1)" }
        }

        /// Segments in Parrot's shape; integer speakers become names.
        var transcriptSegments: [TranscriptSegment] {
            let names = Dictionary(speakers.compactMap { s in s.number.map { ($0, s.name ?? "Speaker \($0 + 1)") } },
                                   uniquingKeysWith: { first, _ in first })
            return segments.map { segment in
                TranscriptSegment(
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    confidence: segment.confidence.map { Float($0) },
                    speaker: segment.speaker.map { names[$0] ?? "Speaker \($0 + 1)" }
                )
            }
        }

        /// The history row. Timestamp is the folder name (unix seconds), with
        /// `datetime` read in the local zone only as a fallback.
        func historyRecord(folder: URL, appBundleID: String?) -> HistoryRecord? {
            let name = folder.lastPathComponent
            guard let timestamp = Self.timestamp(folderName: name, datetime: datetime) else { return nil }
            let wav = folder.appendingPathComponent("output.wav")
            let llm = (llmResult ?? "").isEmpty ? nil : llmResult
            return HistoryRecord(
                timestamp: timestamp,
                rawTranscript: rawResult ?? "",
                finalText: finalText,
                llmText: llm,
                appBundleID: appBundleID,
                appName: (appName ?? "").isEmpty ? nil : appName,
                modeName: modeName,
                folderPath: folder.path,
                audioPath: FileManager.default.fileExists(atPath: wav.path) ? wav.path : nil,
                duration: (duration ?? 0) / 1000,
                processingTime: (processingTime ?? 0) / 1000,
                llmProcessingTime: (languageModelProcessingTime ?? 0) / 1000,
                voiceModel: modelName ?? modelKey,
                languageModel: languageModelName ?? languageModelKey,
                language: languageSelected,
                device: recordingDevice,
                fromFile: false,
                sourceKey: HistoryEntry.SourceKey.superwhisper(folderName: name)
            )
        }

        static func timestamp(folderName: String, datetime: String?) -> Date? {
            if RecordingFolders.isRecordingFolderName(folderName), let seconds = TimeInterval(folderName) {
                return Date(timeIntervalSince1970: seconds)
            }
            guard let datetime else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return formatter.date(from: datetime)
        }
    }

    // MARK: - settings/settings.json

    struct Replacement: Decodable, Equatable {
        var id: String?
        var original: String
        var with: String

        private enum CodingKeys: String, CodingKey { case id, original, with }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.string(.id)
            original = c.string(.original) ?? ""
            with = c.string(.with) ?? ""
        }
    }

    struct SettingsFile: Decodable, Equatable {
        var vocabulary: [String]
        var replacements: [Replacement]
        var modeKeys: [String]

        private enum CodingKeys: String, CodingKey { case vocabulary, replacements, modeKeys }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vocabulary = (try? c.decodeIfPresent([String].self, forKey: .vocabulary)) ?? []
            replacements = (try? c.decodeIfPresent([Replacement].self, forKey: .replacements)) ?? []
            modeKeys = (try? c.decodeIfPresent([String].self, forKey: .modeKeys)) ?? []
        }
    }

    // MARK: - modes/<key>.json

    struct PromptExampleFile: Decodable, Equatable {
        var input: String
        var output: String

        private enum CodingKeys: String, CodingKey { case input, output }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = c.string(.input) ?? ""
            output = c.string(.output) ?? ""
        }
    }

    struct ModeFile: Decodable, Equatable {
        var key: String?
        var name: String?
        var iconName: String?
        var description: String?
        var type: String?
        var version: Int?
        var voiceModelID: String?
        var languageModelID: String?
        var language: String?
        var translateToEnglish: Bool?
        var literalPunctuation: Bool?
        var realtimeOutput: Bool?
        var diarize: Bool?
        var useSystemAudio: Bool?
        var prompt: String?
        var promptExamples: [PromptExampleFile]
        var contextTemplate: String?
        var contextFromSelection: Bool?
        var contextFromClipboard: Bool?
        var contextFromActiveApplication: Bool?
        var activationApps: [String]
        var activationSites: [String]
        var script: String?
        var scriptEnabled: Bool?
        var autocapitalizeInsert: Bool?
        var tone: String?
        var playbackBehavior: String?
        var autoPaste: Bool?
        var shortcut: SuperwhisperShortcut.Payload?
        // Legacy keys migrated on load.
        var smartCapitalization: Bool?
        var adjustOutputVolume: Bool?
        var duckOutputVolume: Bool?
        var pauseMediaPlayback: Bool?

        private enum CodingKeys: String, CodingKey {
            case key, name, iconName, description, type, version, voiceModelID, languageModelID, language
            case translateToEnglish, literalPunctuation, realtimeOutput, diarize, useSystemAudio
            case prompt, promptExamples, contextTemplate, contextFromSelection, contextFromClipboard
            case contextFromActiveApplication, activationApps, activationSites, script, scriptEnabled
            case autocapitalizeInsert, tone, playbackBehavior, autoPaste, shortcut
            case smartCapitalization, adjustOutputVolume, duckOutputVolume, pauseMediaPlayback
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.string(.key)
            name = c.string(.name)
            iconName = c.string(.iconName)
            description = c.string(.description)
            type = c.string(.type)
            version = c.flexibleDouble(.version).map { Int($0) }
            voiceModelID = c.string(.voiceModelID)
            languageModelID = c.string(.languageModelID)
            language = c.string(.language)
            translateToEnglish = c.bool(.translateToEnglish)
            literalPunctuation = c.bool(.literalPunctuation)
            realtimeOutput = c.bool(.realtimeOutput)
            diarize = c.bool(.diarize)
            useSystemAudio = c.bool(.useSystemAudio)
            prompt = c.string(.prompt)
            promptExamples = (try? c.decodeIfPresent([PromptExampleFile].self, forKey: .promptExamples)) ?? []
            contextTemplate = c.string(.contextTemplate)
            contextFromSelection = c.bool(.contextFromSelection)
            contextFromClipboard = c.bool(.contextFromClipboard)
            contextFromActiveApplication = c.bool(.contextFromActiveApplication)
            activationApps = (try? c.decodeIfPresent([String].self, forKey: .activationApps)) ?? []
            activationSites = (try? c.decodeIfPresent([String].self, forKey: .activationSites)) ?? []
            script = c.string(.script)
            scriptEnabled = c.bool(.scriptEnabled)
            autocapitalizeInsert = c.bool(.autocapitalizeInsert)
            tone = c.string(.tone)
            playbackBehavior = c.string(.playbackBehavior)
            autoPaste = c.bool(.autoPaste)
            shortcut = try? c.decodeIfPresent(SuperwhisperShortcut.Payload.self, forKey: .shortcut)
            smartCapitalization = c.bool(.smartCapitalization)
            adjustOutputVolume = c.bool(.adjustOutputVolume)
            duckOutputVolume = c.bool(.duckOutputVolume)
            pauseMediaPlayback = c.bool(.pauseMediaPlayback)
        }
    }
}

// MARK: - Lenient Decoding

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    func bool(_ key: Key) -> Bool? {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil
    }

    /// A number stored as an integer, a double or a numeric string.
    func flexibleDouble(_ key: Key) -> Double? {
        if let value = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return value }
        if let value = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return Double(value) }
        if let value = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(value) }
        return nil
    }
}
