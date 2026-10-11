import Foundation

/// Which Parakeet checkpoint an engine runs.
enum ParakeetVersion: String, Sendable {
    /// English only.
    case v2
    /// 25 European languages. Parrot's default model.
    case v3
}

/// The other on-device recognizers FluidAudio runs. [ASR]
enum FluidASRKind: String, Hashable, Sendable {
    /// Cohere Transcribe, 2B parameters, 14 languages.
    case cohere
    /// Nvidia Canary 1B V2, 25 European languages, translates to English.
    case canary
    /// SenseVoice Small: Chinese, Cantonese, English, Japanese, Korean.
    case senseVoice
    /// Paraformer Large: Mandarin Chinese.
    case paraformer
}

/// A third-party speech vendor reached with the user's own key. [ASR]
enum CloudVoiceVendor: String, Hashable, Sendable, CaseIterable {
    case openAI
    case groq
    case deepgram
    case elevenLabs

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .deepgram: return "Deepgram"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    /// The `ProviderCredentials` entry that holds this vendor's key.
    var providerID: ProviderID {
        switch self {
        case .openAI: return .openAI
        case .groq: return .groq
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenlabs
        }
    }
}

/// A fixed vendor model: what batch requests send and, for vendors that
/// stream, what the live socket asks for.
struct CloudVoicePreset: Hashable, Sendable {
    let vendor: CloudVoiceVendor
    /// The vendor's model id for batch requests.
    let modelID: String
    /// The model id for live text, or nil when the preset cannot stream.
    var realtimeModelID: String?
}

/// Which recognizer runs a voice model.
enum VoiceEngineKind: Hashable, Sendable {
    case parakeet(ParakeetVersion)
    /// A WhisperKit model folder name, e.g. "openai_whisper-tiny".
    case whisperKit(String)
    case fluid(FluidASRKind)
    /// The global OpenAI or Azure provider, configured in settings.
    case cloud(TranscriptionProviderChoice)
    /// A fixed vendor model with the user's own key.
    case vendor(CloudVoicePreset)
}

/// One selectable voice model and what it can do. [ASR]
struct VoiceModelInfo: Identifiable, Hashable, Sendable {
    /// Stored in `Mode.voiceModelID`.
    let id: String
    let name: String
    let detail: String
    let kind: VoiceEngineKind
    let languages: LanguageSet
    let supportsTranslation: Bool
    /// Can show live text while recording.
    let supportsRealtime: Bool
    let supportsDiarization: Bool
    let supportsAutoLanguage: Bool

    /// Approximate download size in bytes; 0 for cloud models.
    var downloadBytes: Int64 = 0
    /// Hidden from the library and pickers unless "Show experimental
    /// models" is on.
    var isExperimental = false
    /// Who makes the model, for the library's provider filter.
    var vendor = ""
    /// Ratings from 1 to 5 for the library's "Speed / Accuracy".
    var speed = 3
    var accuracy = 3
    /// The longest piece of audio sent to the engine at once. Longer
    /// audio is cut into pieces at quiet points. Nil: any length.
    var maxChunkSeconds: TimeInterval?
    /// A requirement worth showing next to the model, if any.
    var requirement: String?

    var isOnDevice: Bool {
        switch kind {
        case .cloud, .vendor: return false
        case .parakeet, .whisperKit, .fluid: return true
        }
    }

    /// The cloud vendor behind the model, if it is a vendor preset.
    var cloudPreset: CloudVoicePreset? {
        if case .vendor(let preset) = kind { return preset }
        return nil
    }

    /// True for vendor models whose live socket also gives the final text.
    var usesRealtimeFinal: Bool {
        supportsRealtime && cloudPreset?.realtimeModelID != nil
    }
}

/// The voice models Parrot offers. [ASR]
enum VoiceModels {

    static let parakeetV3 = VoiceModelInfo(
        id: "parakeet-v3",
        name: "Parakeet V3",
        detail: "On device. 25 European languages. Fast and accurate.",
        kind: .parakeet(.v3),
        languages: .parakeetV3,
        supportsTranslation: false,
        supportsRealtime: true,
        supportsDiarization: true,
        supportsAutoLanguage: true,
        downloadBytes: 483_000_000,
        vendor: "Nvidia",
        speed: 5,
        accuracy: 4
    )

    static let parakeetV2 = VoiceModelInfo(
        id: "parakeet-v2",
        name: "Parakeet V2",
        detail: "On device. English only. Very fast.",
        kind: .parakeet(.v2),
        languages: .english,
        supportsTranslation: false,
        supportsRealtime: true,
        supportsDiarization: true,
        supportsAutoLanguage: false,
        downloadBytes: 473_000_000,
        vendor: "Nvidia",
        speed: 5,
        accuracy: 4
    )

    static let whisper: [VoiceModelInfo] = [
        whisperModel("tiny", "Whisper Tiny", "Smallest and fastest. Basic accuracy.", bytes: 76_000_000, speed: 5, accuracy: 2),
        whisperModel("tiny.en", "Whisper Tiny (English)", "Smallest and fastest. English only.", bytes: 76_000_000, speed: 5, accuracy: 2),
        whisperModel("base", "Whisper Base", "Small and fast.", bytes: 146_000_000, speed: 4, accuracy: 2),
        whisperModel("base.en", "Whisper Base (English)", "Small and fast. English only.", bytes: 146_000_000, speed: 4, accuracy: 2),
        whisperModel("small", "Whisper Small", "Balanced speed and accuracy.", bytes: 486_000_000, speed: 3, accuracy: 3),
        whisperModel("small.en", "Whisper Small (English)", "Balanced. English only.", bytes: 486_000_000, speed: 3, accuracy: 3),
        whisperModel(
            "large-v3", "Whisper Large V3", "Highest accuracy, slowest.",
            folder: "openai_whisper-large-v3_947MB", bytes: 947_000_000, speed: 1, accuracy: 5
        ),
        whisperModel(
            "large-v3-turbo", "Whisper Large V3 Turbo", "Near-best accuracy at higher speed.",
            folder: "openai_whisper-large-v3-v20240930_turbo_632MB", bytes: 632_000_000, speed: 3, accuracy: 5
        ),
    ]

    // MARK: - FluidAudio Engines

    static let cohere = VoiceModelInfo(
        id: "cohere-transcribe",
        name: "Cohere Transcribe",
        detail: "On device. 14 languages, detects which one you speak. Large and slower.",
        kind: .fluid(.cohere),
        languages: .cohere,
        supportsTranslation: false,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: true,
        downloadBytes: 2_190_000_000,
        isExperimental: true,
        vendor: "Cohere",
        speed: 2,
        accuracy: 5,
        requirement: "Needs macOS 15 or later."
    )

    static let canary = VoiceModelInfo(
        id: "canary-1b-v2",
        name: "Canary 1B V2",
        detail: "On device. 25 European languages, can translate to English. Beta.",
        kind: .fluid(.canary),
        languages: .parakeetV3,
        supportsTranslation: true,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: false,
        downloadBytes: 570_000_000,
        isExperimental: true,
        vendor: "Nvidia",
        speed: 3,
        accuracy: 4,
        requirement: "Needs macOS 15 or later."
    )

    static let senseVoice = VoiceModelInfo(
        id: "sensevoice-small",
        name: "SenseVoice Small",
        detail: "On device. Chinese, Cantonese, English, Japanese and Korean. Always detects the language. Very fast.",
        kind: .fluid(.senseVoice),
        languages: .senseVoice,
        supportsTranslation: false,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: true,
        downloadBytes: 475_000_000,
        vendor: "Alibaba",
        speed: 5,
        accuracy: 3,
        // The encoder's longest input is about 108 seconds.
        maxChunkSeconds: 90
    )

    static let paraformer = VoiceModelInfo(
        id: "paraformer-zh",
        name: "Paraformer (Chinese)",
        detail: "On device. Mandarin Chinese only. Very fast.",
        kind: .fluid(.paraformer),
        languages: .mandarin,
        supportsTranslation: false,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: false,
        downloadBytes: 437_000_000,
        vendor: "Alibaba",
        speed: 5,
        accuracy: 3,
        // The decoder reads at most about 30 seconds.
        maxChunkSeconds: 25
    )

    // MARK: - Cloud

    static let cloudOpenAI = VoiceModelInfo(
        id: "cloud-openai",
        name: "OpenAI (cloud)",
        detail: "Uses your OpenAI key and the model set in Models.",
        kind: .cloud(.openAI),
        languages: .whisper,
        supportsTranslation: false,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: true,
        vendor: "OpenAI",
        maxChunkSeconds: 600
    )

    static let cloudAzureWhisper = VoiceModelInfo(
        id: "cloud-azure-whisper",
        name: "Azure Whisper (cloud)",
        detail: "Uses your Azure OpenAI resource and Whisper deployment.",
        kind: .cloud(.azureWhisper),
        languages: .whisper,
        supportsTranslation: false,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: true,
        vendor: "Microsoft",
        maxChunkSeconds: 600
    )

    /// OpenAI and Groq presets: one upload per dictation, the
    /// OpenAI-compatible request shape.
    static let openAIPresets: [VoiceModelInfo] = [
        openAICompatible(.openAI, "gpt-4o-transcribe", "GPT-4o Transcribe", "Strong accuracy in many languages.", translate: false, speed: 3, accuracy: 5),
        openAICompatible(.openAI, "gpt-4o-mini-transcribe", "GPT-4o Mini Transcribe", "Cheaper and faster than GPT-4o Transcribe.", translate: false, speed: 4, accuracy: 4),
        openAICompatible(.openAI, "whisper-1", "OpenAI Whisper", "The original hosted Whisper. Can translate to English.", translate: true, speed: 3, accuracy: 4),
        openAICompatible(.groq, "whisper-large-v3", "Groq Whisper Large V3", "Whisper Large V3 on Groq. Very fast. Can translate to English.", translate: true, speed: 5, accuracy: 5),
        openAICompatible(.groq, "whisper-large-v3-turbo", "Groq Whisper Large V3 Turbo", "Fastest and cheapest Groq Whisper.", translate: false, speed: 5, accuracy: 4),
    ]

    static let deepgramNova3 = deepgram("nova-3", "Deepgram Nova 3", "Top accuracy. Live text and speaker labels.", languages: .deepgram, auto: true, accuracy: 5)
    static let deepgramNova2 = deepgram("nova-2", "Deepgram Nova 2", "Wide language support. Live text and speaker labels.", languages: .deepgram, auto: true, accuracy: 4)
    static let deepgramNova2Medical = deepgram(
        "nova-2-medical", "Deepgram Nova 2 Medical", "Medical terms. English only. Live text and speaker labels.",
        languages: .english, auto: false, accuracy: 4
    )

    static let elevenLabsScribe = VoiceModelInfo(
        id: "elevenlabs-scribe-v2",
        name: "ElevenLabs Scribe V2",
        detail: "Cloud. Over 90 languages. Live text and speaker labels.",
        kind: .vendor(CloudVoicePreset(vendor: .elevenLabs, modelID: "scribe_v2", realtimeModelID: "scribe_v2_realtime")),
        languages: .whisper,
        supportsTranslation: false,
        supportsRealtime: true,
        supportsDiarization: true,
        supportsAutoLanguage: true,
        vendor: "ElevenLabs",
        speed: 4,
        accuracy: 5,
        maxChunkSeconds: 1800
    )

    static let vendorPresets: [VoiceModelInfo] =
        openAIPresets + [deepgramNova3, deepgramNova2, deepgramNova2Medical, elevenLabsScribe]

    /// Every model, in picker order.
    static let all: [VoiceModelInfo] =
        [parakeetV3, parakeetV2] + whisper + [cohere, canary, senseVoice, paraformer]
            + [cloudOpenAI, cloudAzureWhisper] + vendorPresets

    static func model(id: String) -> VoiceModelInfo? {
        all.first { $0.id == id }
    }

    /// The model behind the global provider setting.
    static func model(for choice: TranscriptionProviderChoice) -> VoiceModelInfo {
        switch choice {
        case .parakeet: return parakeetV3
        case .openAI: return cloudOpenAI
        case .azureWhisper: return cloudAzureWhisper
        }
    }

    private static func whisperModel(
        _ size: String, _ name: String, _ detail: String, folder: String? = nil,
        bytes: Int64, speed: Int, accuracy: Int
    ) -> VoiceModelInfo {
        let englishOnly = size.hasSuffix(".en")
        return VoiceModelInfo(
            id: "whisper-\(size)",
            name: name,
            detail: "On device. \(detail)",
            kind: .whisperKit(folder ?? "openai_whisper-\(size)"),
            languages: englishOnly ? .english : .whisper,
            supportsTranslation: !englishOnly,
            supportsRealtime: false,
            supportsDiarization: true,
            supportsAutoLanguage: !englishOnly,
            downloadBytes: bytes,
            vendor: "OpenAI",
            speed: speed,
            accuracy: accuracy
        )
    }

    private static func openAICompatible(
        _ vendor: CloudVoiceVendor, _ modelID: String, _ name: String, _ detail: String,
        translate: Bool, speed: Int, accuracy: Int
    ) -> VoiceModelInfo {
        VoiceModelInfo(
            id: "\(vendor.rawValue.lowercased())-\(modelID)",
            name: name,
            detail: "Cloud, your \(vendor.displayName) key. \(detail)",
            kind: .vendor(CloudVoicePreset(vendor: vendor, modelID: modelID)),
            languages: .whisper,
            supportsTranslation: translate,
            supportsRealtime: false,
            supportsDiarization: false,
            supportsAutoLanguage: true,
            vendor: vendor.displayName,
            speed: speed,
            accuracy: accuracy,
            // Both vendors cap an upload at 25 MB: 600 s of 16-bit WAV is 19 MB.
            maxChunkSeconds: 600
        )
    }

    private static func deepgram(
        _ modelID: String, _ name: String, _ detail: String,
        languages: LanguageSet, auto: Bool, accuracy: Int
    ) -> VoiceModelInfo {
        VoiceModelInfo(
            id: "deepgram-\(modelID)",
            name: name,
            detail: "Cloud, your Deepgram key. \(detail)",
            kind: .vendor(CloudVoicePreset(vendor: .deepgram, modelID: modelID, realtimeModelID: modelID)),
            languages: languages,
            supportsTranslation: false,
            supportsRealtime: true,
            supportsDiarization: true,
            supportsAutoLanguage: auto,
            vendor: "Deepgram",
            speed: 5,
            accuracy: accuracy,
            maxChunkSeconds: 1800
        )
    }
}

/// What the mode editor allows for a mode and its voice model. [ASR]
struct VoiceModeRules {
    let model: VoiceModelInfo
    let mode: Mode

    var canEnableRealtime: Bool { model.supportsRealtime && !mode.diarize }
    var canEnableDiarize: Bool { model.supportsDiarization && !mode.realtimeOutput }

    /// Why live text cannot be turned on, or nil when it can (or is on).
    var realtimeBlockedReason: String? {
        guard !mode.realtimeOutput else { return nil }
        if !model.supportsRealtime { return "Live text works with Parakeet, Deepgram and ElevenLabs models." }
        if mode.diarize { return "Cannot turn on live text while speaker identification is on for this model." }
        return nil
    }

    /// Why speaker identification cannot be turned on, or nil when it can.
    var diarizeBlockedReason: String? {
        guard !mode.diarize else { return nil }
        if !model.supportsDiarization { return "This model cannot identify speakers." }
        if mode.realtimeOutput { return "Cannot identify speakers while live text is on for this model." }
        return nil
    }

    /// The mode with every voice setting the model cannot honor reset.
    /// Applied when the user picks another model.
    static func adjusted(_ mode: Mode, for model: VoiceModelInfo) -> Mode {
        var mode = mode
        if !LanguageCatalog.choices(for: model).contains(where: { $0.code == mode.language }) {
            mode.language = LanguageCatalog.defaultCode(for: model)
        }
        if !model.supportsTranslation { mode.translateToEnglish = false }
        if !model.supportsRealtime { mode.realtimeOutput = false }
        if !model.supportsDiarization { mode.diarize = false }
        return mode
    }
}
