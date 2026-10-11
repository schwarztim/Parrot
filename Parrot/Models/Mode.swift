import Foundation

// MARK: - Mode

/// A saved dictation recipe: voice model, language model, instructions,
/// context sources, activation rules and per-mode overrides.
///
/// Frozen. Every field a workstream needs is declared here; fields added
/// after `refinementPrompt` and `appBundleIDs` decode with
/// `decodeIfPresent` and a default, so a `modes.json` written before they
/// existed still loads. Encoding writes every field (optionals only when set).
struct Mode: Codable, Identifiable, Hashable {
    var id: UUID
    /// Stable identifier, also the file name once modes are stored one file
    /// per mode. Defaults to the lowercased `id` so it never changes.
    var key: String
    var name: String
    var description: String
    var isDefault: Bool
    /// Selects the built-in preset for this mode.
    var type: ModeType
    /// SF Symbol name. Empty means the type's default icon.
    var iconName: String

    // MARK: Voice

    /// Speech-to-text model id. Empty means the app's current engine.
    var voiceModelID: String
    /// Spoken language code, or "auto".
    var language: String
    var translateToEnglish: Bool
    /// Spoken punctuation words become symbols.
    var literalPunctuation: Bool
    /// Show text while recording.
    var realtimeOutput: Bool
    /// Label speakers as Speaker 1, 2, 3.
    var diarize: Bool
    /// Record system audio along with the microphone.
    var useSystemAudio: Bool

    // MARK: Language model

    /// Language model id. Empty means the global refinement provider.
    var languageModelID: String
    /// Nil means not set (behaves as balanced).
    var tone: Tone?
    /// Per-mode refinement directive (the spec's `prompt`). Nil or empty
    /// falls back to `RefinementService.defaultDirective`. Optional so modes
    /// saved before this field existed still decode.
    var refinementPrompt: String?
    /// User few-shot pairs.
    var promptExamples: [PromptExample]

    // MARK: Context

    /// Instruction prefix for copied-text context. Empty means Parrot's default.
    var contextTemplate: String
    var contextFromSelection: Bool
    var contextFromClipboard: Bool
    var contextFromActiveApplication: Bool

    // MARK: Activation

    /// Bundle IDs of apps that should auto-select this mode when you dictate
    /// into them (the spec's `activationApps`). Optional so pre-existing
    /// modes.json decodes unchanged.
    var appBundleIDs: [String]?
    /// Website domains that auto-select this mode when a browser is frontmost.
    var activationSites: [String]

    // MARK: Output

    /// AppleScript source; `{{user_message}}` is replaced with the dictation.
    var script: String
    var scriptEnabled: Bool
    /// Per-mode paste override. Nil means the global setting.
    var autoPaste: Bool?
    /// Adjust the first word's case to the text around the cursor.
    var autocapitalizeInsert: Bool

    // MARK: Audio and shortcut

    /// Nil means the global playback default.
    var playbackBehavior: PlaybackBehavior?
    /// Global shortcut that starts a recording in this mode.
    var shortcut: ModeShortcut?

    /// Schema version of the stored mode.
    var version: Int

    init(
        id: UUID = UUID(),
        key: String? = nil,
        name: String,
        description: String = "",
        isDefault: Bool = false,
        type: ModeType = .custom,
        iconName: String = "",
        voiceModelID: String = "",
        language: String = "auto",
        translateToEnglish: Bool = false,
        literalPunctuation: Bool = false,
        realtimeOutput: Bool = false,
        diarize: Bool = false,
        useSystemAudio: Bool = false,
        languageModelID: String = "",
        tone: Tone? = nil,
        refinementPrompt: String? = nil,
        promptExamples: [PromptExample] = [],
        contextTemplate: String = "",
        contextFromSelection: Bool = false,
        contextFromClipboard: Bool = false,
        contextFromActiveApplication: Bool = false,
        appBundleIDs: [String]? = nil,
        activationSites: [String] = [],
        script: String = "",
        scriptEnabled: Bool = false,
        autoPaste: Bool? = nil,
        autocapitalizeInsert: Bool = true,
        playbackBehavior: PlaybackBehavior? = nil,
        shortcut: ModeShortcut? = nil,
        version: Int = Mode.currentVersion
    ) {
        self.id = id
        self.key = key ?? Mode.defaultKey(for: id)
        self.name = name
        self.description = description
        self.isDefault = isDefault
        self.type = type
        self.iconName = iconName
        self.voiceModelID = voiceModelID
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.literalPunctuation = literalPunctuation
        self.realtimeOutput = realtimeOutput
        self.diarize = diarize
        self.useSystemAudio = useSystemAudio
        self.languageModelID = languageModelID
        self.tone = tone
        self.refinementPrompt = refinementPrompt
        self.promptExamples = promptExamples
        self.contextTemplate = contextTemplate
        self.contextFromSelection = contextFromSelection
        self.contextFromClipboard = contextFromClipboard
        self.contextFromActiveApplication = contextFromActiveApplication
        self.appBundleIDs = appBundleIDs
        self.activationSites = activationSites
        self.script = script
        self.scriptEnabled = scriptEnabled
        self.autoPaste = autoPaste
        self.autocapitalizeInsert = autocapitalizeInsert
        self.playbackBehavior = playbackBehavior
        self.shortcut = shortcut
        self.version = version
    }

    /// Schema version written by this build.
    static let currentVersion = 1

    /// The key a mode gets when none was stored.
    static func defaultKey(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Creates the built-in default mode.
    static var defaultMode: Mode {
        Mode(
            name: "Default",
            description: "General-purpose transcription mode",
            isDefault: true
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, key, name, description, isDefault, type, iconName
        case voiceModelID, language, translateToEnglish, literalPunctuation
        case realtimeOutput, diarize, useSystemAudio
        case languageModelID, tone, refinementPrompt, promptExamples
        case contextTemplate, contextFromSelection, contextFromClipboard, contextFromActiveApplication
        case appBundleIDs, activationSites
        case script, scriptEnabled, autoPaste, autocapitalizeInsert
        case playbackBehavior, shortcut, version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        self.id = id
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? Mode.defaultKey(for: id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        type = try c.decodeIfPresent(ModeType.self, forKey: .type) ?? .custom
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName) ?? ""
        voiceModelID = try c.decodeIfPresent(String.self, forKey: .voiceModelID) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        translateToEnglish = try c.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false
        literalPunctuation = try c.decodeIfPresent(Bool.self, forKey: .literalPunctuation) ?? false
        realtimeOutput = try c.decodeIfPresent(Bool.self, forKey: .realtimeOutput) ?? false
        diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? false
        useSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .useSystemAudio) ?? false
        languageModelID = try c.decodeIfPresent(String.self, forKey: .languageModelID) ?? ""
        tone = try c.decodeIfPresent(Tone.self, forKey: .tone)
        refinementPrompt = try c.decodeIfPresent(String.self, forKey: .refinementPrompt)
        promptExamples = try c.decodeIfPresent([PromptExample].self, forKey: .promptExamples) ?? []
        contextTemplate = try c.decodeIfPresent(String.self, forKey: .contextTemplate) ?? ""
        contextFromSelection = try c.decodeIfPresent(Bool.self, forKey: .contextFromSelection) ?? false
        contextFromClipboard = try c.decodeIfPresent(Bool.self, forKey: .contextFromClipboard) ?? false
        contextFromActiveApplication = try c.decodeIfPresent(Bool.self, forKey: .contextFromActiveApplication) ?? false
        appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs)
        activationSites = try c.decodeIfPresent([String].self, forKey: .activationSites) ?? []
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        scriptEnabled = try c.decodeIfPresent(Bool.self, forKey: .scriptEnabled) ?? false
        autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste)
        autocapitalizeInsert = try c.decodeIfPresent(Bool.self, forKey: .autocapitalizeInsert) ?? true
        playbackBehavior = try c.decodeIfPresent(PlaybackBehavior.self, forKey: .playbackBehavior)
        shortcut = try c.decodeIfPresent(ModeShortcut.self, forKey: .shortcut)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Mode.currentVersion
    }
}

// MARK: - Mode Types

/// The built-in preset a mode starts from.
enum ModeType: String, Codable, CaseIterable, Hashable {
    case `super`
    case voice
    case message
    case email
    case note
    case meeting
    case custom
}

/// Formality of the cleaned transcript.
enum Tone: String, Codable, CaseIterable, Hashable {
    case casual
    case semiCasual = "semi-casual"
    case balanced
    case semiFormal = "semi-formal"
    case formal
}

/// One user few-shot pair: what was said and what it should become.
struct PromptExample: Codable, Identifiable, Hashable {
    var id: UUID
    var input: String
    var output: String

    init(id: UUID = UUID(), input: String, output: String) {
        self.id = id
        self.input = input
        self.output = output
    }
}

/// What happens to playing media while recording.
enum PlaybackBehavior: String, Codable, CaseIterable, Hashable {
    case keepPlaying
    case pause
    case duck
    case mute
}

/// A global shortcut that starts a recording in one mode. Uses the same
/// conventions as `HotkeyBinding`: a virtual key code, the raw value of
/// `NSEvent.ModifierFlags`, and an optional mouse button number.
struct ModeShortcut: Codable, Hashable {
    var keyCode: Int
    var modifiers: UInt
    var mouseButton: Int?

    init(keyCode: Int, modifiers: UInt = 0, mouseButton: Int? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButton = mouseButton
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, mouseButton
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode) ?? 0
        modifiers = try c.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0
        mouseButton = try c.decodeIfPresent(Int.self, forKey: .mouseButton)
    }
}
