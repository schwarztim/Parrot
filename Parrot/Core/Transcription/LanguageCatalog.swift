import Foundation

/// A spoken language a voice model can be told to expect.
struct VoiceLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }
}

/// Which language list a voice model draws from.
enum LanguageSet: Hashable, Sendable {
    /// The Whisper family's list, about 100 languages.
    case whisper
    /// Parakeet V3's 25 European languages.
    case parakeetV3
    case english
}

/// Per-model language lists for the mode editor. [ASR]
enum LanguageCatalog {

    /// The mode language value meaning "detect it".
    static let automatic = "auto"

    static let automaticChoice = VoiceLanguage(code: automatic, name: "Automatic")

    /// The languages a model accepts, sorted by name.
    static func languages(for model: VoiceModelInfo) -> [VoiceLanguage] {
        switch model.languages {
        case .whisper: return whisper
        case .parakeetV3: return parakeetV3
        case .english: return [VoiceLanguage(code: "en", name: "English")]
        }
    }

    /// Picker entries: Automatic first when the model detects language.
    static func choices(for model: VoiceModelInfo) -> [VoiceLanguage] {
        let list = languages(for: model)
        return model.supportsAutoLanguage ? [automaticChoice] + list : list
    }

    /// What a mode falls back to when its language does not fit the model.
    static func defaultCode(for model: VoiceModelInfo) -> String {
        model.supportsAutoLanguage ? automatic : (languages(for: model).first?.code ?? "en")
    }

    static func name(for code: String) -> String {
        if code == automatic { return automaticChoice.name }
        return whisper.first { $0.code == code }?.name ?? code
    }

    // MARK: - Lists

    /// Parakeet V3's languages.
    static let parakeetV3Codes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    static let parakeetV3: [VoiceLanguage] = whisper.filter { parakeetV3Codes.contains($0.code) }

    /// Languages the Whisper models were trained on, sorted by name.
    static let whisper: [VoiceLanguage] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"),
        ("hy", "Armenian"), ("as", "Assamese"), ("az", "Azerbaijani"), ("ba", "Bashkir"),
        ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
        ("br", "Breton"), ("bg", "Bulgarian"), ("yue", "Cantonese"), ("ca", "Catalan"),
        ("zh", "Chinese"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"),
        ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"), ("fo", "Faroese"),
        ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"),
        ("de", "German"), ("el", "Greek"), ("gu", "Gujarati"), ("ht", "Haitian Creole"),
        ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"),
        ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"),
        ("km", "Khmer"), ("ko", "Korean"), ("lo", "Lao"), ("la", "Latin"),
        ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"), ("lb", "Luxembourgish"),
        ("mk", "Macedonian"), ("mg", "Malagasy"), ("ms", "Malay"), ("ml", "Malayalam"),
        ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"), ("mn", "Mongolian"),
        ("my", "Myanmar"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Nynorsk"),
        ("oc", "Occitan"), ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"),
        ("pt", "Portuguese"), ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"), ("sd", "Sindhi"),
        ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"),
        ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"),
        ("tl", "Tagalog"), ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"),
        ("te", "Telugu"), ("th", "Thai"), ("bo", "Tibetan"), ("tr", "Turkish"),
        ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("uz", "Uzbek"),
        ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba"),
    ].map { VoiceLanguage(code: $0.0, name: $0.1) }
}
