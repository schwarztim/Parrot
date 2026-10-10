import Foundation

/// Which Parakeet checkpoint an engine runs.
enum ParakeetVersion: String, Sendable {
    /// English only.
    case v2
    /// 25 European languages. Parrot's default model.
    case v3
}

/// Which recognizer runs a voice model.
enum VoiceEngineKind: Hashable, Sendable {
    case parakeet(ParakeetVersion)
    /// A WhisperKit model folder name, e.g. "openai_whisper-tiny".
    case whisperKit(String)
    case cloud(TranscriptionProviderChoice)
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

    var isOnDevice: Bool {
        if case .cloud = kind { return false }
        return true
    }
}

/// The voice models Parrot offers. ASR.2 adds more engines and cloud
/// vendors to this list. [ASR]
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
        supportsAutoLanguage: true
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
        supportsAutoLanguage: false
    )

    static let whisper: [VoiceModelInfo] = [
        whisperModel("tiny", "Whisper Tiny", "Smallest and fastest. Basic accuracy."),
        whisperModel("tiny.en", "Whisper Tiny (English)", "Smallest and fastest. English only."),
        whisperModel("base", "Whisper Base", "Small and fast."),
        whisperModel("base.en", "Whisper Base (English)", "Small and fast. English only."),
        whisperModel("small", "Whisper Small", "Balanced speed and accuracy."),
        whisperModel("small.en", "Whisper Small (English)", "Balanced. English only."),
        whisperModel("large-v3", "Whisper Large V3", "Highest accuracy, slowest.", folder: "openai_whisper-large-v3_947MB"),
        whisperModel(
            "large-v3-turbo", "Whisper Large V3 Turbo", "Near-best accuracy at higher speed.",
            folder: "openai_whisper-large-v3-v20240930_turbo_632MB"
        ),
    ]

    static let cloudOpenAI = VoiceModelInfo(
        id: "cloud-openai",
        name: "OpenAI (cloud)",
        detail: "Uses your OpenAI key and the model set in Models.",
        kind: .cloud(.openAI),
        languages: .whisper,
        supportsTranslation: false,
        supportsRealtime: false,
        supportsDiarization: false,
        supportsAutoLanguage: true
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
        supportsAutoLanguage: true
    )

    /// Every model, in picker order.
    static let all: [VoiceModelInfo] = [parakeetV3, parakeetV2] + whisper + [cloudOpenAI, cloudAzureWhisper]

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
        _ size: String, _ name: String, _ detail: String, folder: String? = nil
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
            supportsAutoLanguage: !englishOnly
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
        if !model.supportsRealtime { return "Live text works with Parakeet models." }
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
