import Foundation
import WhisperKit

/// On-device Whisper through WhisperKit (CoreML): one model folder per
/// engine, a fixed or detected language, and translate to English. [ASR]
///
/// Models live where WhisperKit downloads them by default,
/// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<folder>`.
actor WhisperKitEngine: BatchTranscriptionEngine {

    /// WhisperKit's model folder name, e.g. "openai_whisper-tiny".
    nonisolated let variant: String
    nonisolated let downloadBase: URL

    private var whisperKit: WhisperKit?

    static var defaultDownloadBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    init(variant: String, downloadBase: URL = WhisperKitEngine.defaultDownloadBase) {
        self.variant = variant
        self.downloadBase = downloadBase
    }

    nonisolated var modelFolder: URL {
        Self.modelFolder(variant: variant, downloadBase: downloadBase)
    }

    /// English-only checkpoints end in ".en" and cannot translate.
    nonisolated var isEnglishOnly: Bool { variant.hasSuffix(".en") }

    static func modelFolder(variant: String, downloadBase: URL = defaultDownloadBase) -> URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// True when the three CoreML parts are on disk.
    static func isDownloaded(variant: String, downloadBase: URL = defaultDownloadBase) -> Bool {
        let folder = modelFolder(variant: variant, downloadBase: downloadBase)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    // MARK: - Lifecycle

    func isDownloaded() -> Bool {
        Self.isDownloaded(variant: variant, downloadBase: downloadBase)
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: variant, downloadBase: downloadBase) { update in
            progress(update.fractionCompleted)
        }
    }

    func load() async throws {
        guard whisperKit == nil else { return }
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: downloadBase,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        whisperKit = kit
        diagLog("[Parrot:Whisper] \(variant) loaded")
    }

    func unload() async {
        guard let kit = whisperKit else { return }
        await kit.unloadModels()
        whisperKit = nil
        diagLog("[Parrot:Whisper] \(variant) unloaded")
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        guard let kit = whisperKit else { throw TranscriptionFailure.engineNotReady }

        let language = isEnglishOnly ? nil : options.language
        let decode = DecodingOptions(
            verbose: false,
            task: options.translateToEnglish && !isEnglishOnly ? .translate : .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: !isEnglishOnly && language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false
        )
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: decode)

        let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(text: text, start: Double(segment.start), end: Double(segment.end))
        }
        let text = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let detected = results.first?.language
        return TranscriptOutput(
            text: text,
            segments: segments,
            language: isEnglishOnly ? "en" : (language ?? (detected?.isEmpty == false ? detected : nil))
        )
    }
}
