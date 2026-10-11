import FluidAudio
import Foundation
import NaturalLanguage

/// Cohere Transcribe, Canary, SenseVoice and Paraformer through FluidAudio,
/// in the router's engine shape. [ASR]
///
/// Models download into FluidAudio's shared cache,
/// `~/Library/Application Support/FluidAudio/Models/<folder>`, next to
/// Parakeet and Silero VAD. Cohere and Canary ship weights that need
/// macOS 15; on macOS 14 their load fails with a plain message.
actor FluidASREngine: BatchTranscriptionEngine {

    nonisolated let kind: FluidASRKind

    private var cohereModels: CoherePipeline.LoadedModels?
    private var coherePipeline: CoherePipeline?
    private var canaryModels: CanaryModels?
    private var senseVoice: SenseVoiceManager?
    private var paraformer: ParaformerManager?

    init(kind: FluidASRKind) {
        self.kind = kind
    }

    // MARK: - Where Models Live

    /// FluidAudio's model cache root. FluidAudio keeps its own copy of this
    /// path private, so it is rebuilt here the same way.
    static var modelsRoot: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated var repo: Repo {
        switch kind {
        case .cohere: return .cohereTranscribeCoreml
        case .canary: return .canary1bV2
        case .senseVoice: return .senseVoiceSmall
        case .paraformer: return .paraformerLargeZh
        }
    }

    /// The folder this engine's model files land in.
    nonisolated var cacheDirectory: URL {
        Self.modelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    /// Cohere's int8 encoder and Canary's int4 weights need macOS 15.
    nonisolated var needsMacOS15: Bool {
        kind == .cohere || kind == .canary
    }

    private nonisolated var displayName: String {
        switch kind {
        case .cohere: return VoiceModels.cohere.name
        case .canary: return VoiceModels.canary.name
        case .senseVoice: return VoiceModels.senseVoice.name
        case .paraformer: return VoiceModels.paraformer.name
        }
    }

    // MARK: - Lifecycle

    func isDownloaded() -> Bool {
        switch kind {
        case .cohere:
            return ModelFiles.complete(
                at: cacheDirectory,
                required: [
                    ModelNames.CohereTranscribe.encoderCompiledFile,
                    ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile,
                    ModelNames.CohereTranscribe.vocab,
                ]
            )
        case .canary:
            return CanaryModels.modelsExist(at: cacheDirectory, precision: .int4)
                && !ModelFiles.hasPartialDownload(in: cacheDirectory)
        case .senseVoice:
            return SenseVoiceModels.modelsExist(at: cacheDirectory)
        case .paraformer:
            return ParaformerModels.modelsExist(at: cacheDirectory)
        }
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let handler: ProgressHandler = { update in progress(update.fractionCompleted) }
        switch kind {
        case .cohere:
            try await ModelHub.download(.cohereTranscribeCoreml, to: Self.modelsRoot, progressHandler: handler)
        case .canary:
            _ = try await CanaryModels.download(precision: .int4, progressHandler: handler)
        case .senseVoice:
            _ = try await SenseVoiceModels.download(progressHandler: handler)
        case .paraformer:
            _ = try await ParaformerModels.download(progressHandler: handler)
        }
    }

    func load() async throws {
        if isLoaded { return }
        if needsMacOS15, !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        ) {
            throw TranscriptionFailure.loadFailed(displayName, "it needs macOS 15 or later.")
        }
        let directory = cacheDirectory
        switch kind {
        case .cohere:
            cohereModels = try await CoherePipeline.loadModels(
                encoderDir: directory, decoderDir: directory, vocabDir: directory, decoderVariant: .v2
            )
            coherePipeline = CoherePipeline()
        case .canary:
            canaryModels = try CanaryModels.load(from: directory, precision: .int4)
        case .senseVoice:
            senseVoice = SenseVoiceManager(models: try SenseVoiceModels.load(from: directory))
        case .paraformer:
            paraformer = ParaformerManager(models: try ParaformerModels.load(from: directory))
        }
        diagLog("[Parrot:Fluid] \(displayName) loaded")
    }

    func unload() async {
        guard isLoaded else { return }
        cohereModels = nil
        coherePipeline = nil
        canaryModels = nil
        senseVoice = nil
        paraformer = nil
        diagLog("[Parrot:Fluid] \(displayName) unloaded")
    }

    private var isLoaded: Bool {
        cohereModels != nil || canaryModels != nil || senseVoice != nil || paraformer != nil
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        switch kind {
        case .cohere:
            return try await transcribeCohere(samples, options: options)
        case .canary:
            guard let models = canaryModels else { throw TranscriptionFailure.engineNotReady }
            let source = options.language ?? "en"
            let target = options.translateToEnglish ? "en" : source
            let manager = CanaryManager(models: models, prompt: Self.canaryPrompt(source: source, target: target, models: models))
            let text = try await manager.transcribe(audio: samples)
            return TranscriptOutput(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: target)
        case .senseVoice:
            guard let senseVoice else { throw TranscriptionFailure.engineNotReady }
            let result = try await senseVoice.transcribeDetailed(audio: samples)
            let language = result.language == "nospeech" ? nil : result.language
            let text = result.language == "nospeech" ? "" : result.text
            return TranscriptOutput(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: language)
        case .paraformer:
            guard let paraformer else { throw TranscriptionFailure.engineNotReady }
            let text = try await paraformer.transcribe(audio: samples)
            return TranscriptOutput(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: "zh")
        }
    }

    /// Cohere with a fixed language, or with language identification: a
    /// probe of the first seconds decodes as English, the probe text names
    /// the language, and a non-English language decodes the whole clip
    /// again with that language's prompt. A language Cohere does not know
    /// falls back to English.
    private func transcribeCohere(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        guard let models = cohereModels, let pipeline = coherePipeline else {
            throw TranscriptionFailure.engineNotReady
        }
        if let code = options.language {
            let language = CohereAsrConfig.Language(rawValue: code) ?? .english
            let result = try await pipeline.transcribeLong(audio: samples, models: models, language: language)
            return TranscriptOutput(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), language: language.rawValue)
        }

        let probeCount = min(samples.count, Int(CohereLanguageID.probeSeconds * 16_000))
        let probe = try await pipeline.transcribeLong(
            audio: Array(samples.prefix(probeCount)), models: models, language: .english
        )
        let guessed = CohereLanguageID.guess(text: probe.text).flatMap(CohereAsrConfig.Language.init(rawValue:)) ?? .english
        diagLog("[Parrot:Fluid] Cohere language identification chose \(guessed.rawValue)")
        if guessed == .english, probeCount == samples.count {
            return TranscriptOutput(text: probe.text.trimmingCharacters(in: .whitespacesAndNewlines), language: "en")
        }
        let result = try await pipeline.transcribeLong(audio: samples, models: models, language: guessed)
        return TranscriptOutput(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), language: guessed.rawValue)
    }

    /// Canary's task prompt with the source and target language tokens
    /// looked up in its vocabulary. A language token it lacks keeps
    /// FluidAudio's English prompt.
    static func canaryPrompt(source: String, target: String, models: CanaryModels) -> [Int32] {
        var prompt = CanaryConfig.promptEnTranscribePnc
        let vocabulary = models.tokenizer.vocabulary
        func id(for code: String) -> Int32? {
            vocabulary.first { $0.value == "<|\(code)|>" }.map { Int32($0.key) }
        }
        guard prompt.count >= 6, let sourceID = id(for: source), let targetID = id(for: target) else {
            return prompt
        }
        prompt[4] = sourceID
        prompt[5] = targetID
        return prompt
    }
}

// MARK: - Language Identification

/// Names the language of a short transcript for Cohere Transcribe, from
/// the 14 it knows. Apple's NaturalLanguage does the guessing. [ASR]
enum CohereLanguageID {
    /// Seconds of audio decoded to guess the language.
    static let probeSeconds: TimeInterval = 10
    /// Below this confidence the guess is ignored (English is used).
    static let minimumConfidence = 0.5

    private static let candidates: [String: NLLanguage] = [
        "en": .english, "fr": .french, "de": .german, "es": .spanish, "it": .italian,
        "pt": .portuguese, "nl": .dutch, "pl": .polish, "el": .greek, "ar": .arabic,
        "ja": .japanese, "zh": .simplifiedChinese, "vi": .vietnamese, "ko": .korean,
    ]

    /// The language code, or nil when the text is too short or unclear.
    static func guess(text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(candidates.values) + [.traditionalChinese]
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence
        else { return nil }
        if language == .traditionalChinese { return "zh" }
        return candidates.first { $0.value == language }?.key
    }
}

// MARK: - Model Files

/// Checks on a downloaded model folder. [ASR]
enum ModelFiles {
    /// True when every required file is there and no download is half done.
    static func complete(at directory: URL, required: [String]) -> Bool {
        let fm = FileManager.default
        return required.allSatisfy { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
            && !hasPartialDownload(in: directory)
    }

    /// True when a cancelled or broken download left staging files behind.
    static func hasPartialDownload(in directory: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in walker where url.pathExtension == "partial" {
            return true
        }
        return false
    }

    /// Bytes the folder takes on disk, counting every file inside.
    static func diskSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
