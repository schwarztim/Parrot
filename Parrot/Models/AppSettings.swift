import AppKit
import CoreGraphics
import Foundation

// MARK: - RecordingWindowStyle

enum RecordingWindowStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case mini
    case none

    var id: String { rawValue }

    var description: String {
        switch self {
        case .classic: return "Larger window with full waveform visualization"
        case .mini: return "Compact horizontal bar"
        case .none: return "No recording window shown"
        }
    }
}

// MARK: - HotkeyBinding

struct HotkeyBinding: Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var displayName: String
    /// Non-nil for mouse button bindings (2 = middle, 3 = button 4, etc.).
    var mouseButton: Int?

    // MARK: - Static Presets

    /// Default hotkey: Right Option key (keyCode 0x3D).
    static let defaultHotkey = HotkeyBinding(
        keyCode: 0x3D,
        modifiers: [],
        displayName: "Right Option"
    )

    /// Alias for views that reference `.defaultToggle`.
    static let defaultToggle = defaultHotkey

    /// Empty binding representing no hotkey assigned.
    static let empty = HotkeyBinding(
        keyCode: 0,
        modifiers: [],
        displayName: "None"
    )

    /// The corresponding CGEventFlags for use with CGEvent-based hotkey listeners.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}

// MARK: - HotkeyBinding + Hashable

extension HotkeyBinding: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
        hasher.combine(displayName)
        hasher.combine(mouseButton)
    }
}

// MARK: - HotkeyBinding + Codable

extension HotkeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierRawValue
        case displayName
        case mouseButton
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawValue = try container.decode(UInt.self, forKey: .modifierRawValue)
        modifiers = NSEvent.ModifierFlags(rawValue: rawValue)
        displayName = try container.decode(String.self, forKey: .displayName)
        mouseButton = try container.decodeIfPresent(Int.self, forKey: .mouseButton)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifierRawValue)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(mouseButton, forKey: .mouseButton)
    }
}

// MARK: - UserDefaults Keys

private enum SettingsKey {
    // Legacy enhance-mode keys, migrated to the Azure OpenAI refinement fields.
    static let enhanceEndpoint = "parrot.enhanceEndpoint"
    static let enhanceModel = "parrot.enhanceModel"
    static let refinementEnabled = "parrot.refinementEnabled"
    static let refinementProvider = "parrot.refinementProvider"
    static let localServerBaseURL = "parrot.localServerBaseURL"
    static let localServerModel = "parrot.localServerModel"
    static let openAIModel = "parrot.openAIModel"
    static let azureOpenAIEndpoint = "parrot.azureOpenAIEndpoint"
    static let azureOpenAIDeployment = "parrot.azureOpenAIDeployment"
    static let azureOpenAIAPIVersion = "parrot.azureOpenAIAPIVersion"
    static let anthropicModel = "parrot.anthropicModel"
    static let transcriptionProvider = "parrot.transcriptionProvider"
    static let openAITranscriptionModel = "parrot.openAITranscriptionModel"
    static let azureWhisperDeployment = "parrot.azureWhisperDeployment"
    static let recordingWindowStyle = "parrot.recordingWindowStyle"
    static let hotkeyBinding = "parrot.hotkeyBinding"
    static let cancelHotkeyBinding = "parrot.cancelHotkeyBinding"
    static let pushToTalkBinding = "parrot.pushToTalkBinding"
    static let launchAtLogin = "parrot.launchAtLogin"
    static let autoMicVolume = "parrot.autoMicVolume"
    static let silenceRemoval = "parrot.silenceRemoval"
    static let soundEffectsEnabled = "parrot.soundEffectsEnabled"
    static let soundEffectsVolume = "parrot.soundEffectsVolume"
    static let selectedInputDeviceID = "parrot.selectedInputDeviceID"
    static let hasCompletedOnboarding = "parrot.hasCompletedOnboarding"
    static let selectedModeID = "parrot.selectedModeID"
}

// MARK: - AppSettings

@Observable
final class AppSettings {

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadAll()
    }

    // MARK: - Keychain Constants

    /// Legacy enhance-mode service, migrated to `azureKeychainService`.
    private static let legacyKeychainService = "com.parrot.enhance"
    private static let openAIKeychainService = "com.parrot.openai"
    private static let azureKeychainService = "com.parrot.azure-openai"
    private static let anthropicKeychainService = "com.parrot.anthropic"
    private static let localServerKeychainService = "com.parrot.local-server"
    private static let keychainAccount = "apiKey"

    // MARK: - Refinement Settings

    /// When true, transcripts are refined by the selected LLM provider before
    /// pasting. When false (or the provider is unconfigured), the raw
    /// transcript is pasted unchanged, so the app works fully offline.
    var refinementEnabled: Bool = false {
        didSet { defaults.set(refinementEnabled, forKey: SettingsKey.refinementEnabled) }
    }

    var refinementProvider: RefinementProvider = .localServer {
        didSet { defaults.set(refinementProvider.rawValue, forKey: SettingsKey.refinementProvider) }
    }

    /// OpenAI-compatible base URL for local servers (Ollama, LM Studio,
    /// llama.cpp, vLLM), including the version path.
    var localServerBaseURL: String = "http://localhost:11434/v1" {
        didSet { defaults.set(localServerBaseURL, forKey: SettingsKey.localServerBaseURL) }
    }

    var localServerModel: String = "" {
        didSet { defaults.set(localServerModel, forKey: SettingsKey.localServerModel) }
    }

    var openAIModel: String = "gpt-4o-mini" {
        didSet { defaults.set(openAIModel, forKey: SettingsKey.openAIModel) }
    }

    /// Azure resource endpoint, e.g. "https://my-resource.openai.azure.com".
    var azureOpenAIEndpoint: String = "" {
        didSet { defaults.set(azureOpenAIEndpoint, forKey: SettingsKey.azureOpenAIEndpoint) }
    }

    /// Azure chat-model deployment name.
    var azureOpenAIDeployment: String = "" {
        didSet { defaults.set(azureOpenAIDeployment, forKey: SettingsKey.azureOpenAIDeployment) }
    }

    var azureOpenAIAPIVersion: String = "2024-10-21" {
        didSet { defaults.set(azureOpenAIAPIVersion, forKey: SettingsKey.azureOpenAIAPIVersion) }
    }

    var anthropicModel: String = "claude-haiku-4-5" {
        didSet { defaults.set(anthropicModel, forKey: SettingsKey.anthropicModel) }
    }

    // MARK: - Transcription Settings

    var transcriptionProvider: TranscriptionProviderChoice = .parakeet {
        didSet { defaults.set(transcriptionProvider.rawValue, forKey: SettingsKey.transcriptionProvider) }
    }

    var openAITranscriptionModel: String = "whisper-1" {
        didSet { defaults.set(openAITranscriptionModel, forKey: SettingsKey.openAITranscriptionModel) }
    }

    /// Azure Whisper deployment name. Uses the same resource endpoint, key,
    /// and API version as Azure OpenAI refinement.
    var azureWhisperDeployment: String = "" {
        didSet { defaults.set(azureWhisperDeployment, forKey: SettingsKey.azureWhisperDeployment) }
    }

    // MARK: - API Keys (Keychain, one service per provider, never logged)

    var openAIKey: String = "" {
        didSet { saveKey(openAIKey, service: Self.openAIKeychainService) }
    }

    var azureOpenAIKey: String = "" {
        didSet { saveKey(azureOpenAIKey, service: Self.azureKeychainService) }
    }

    var anthropicKey: String = "" {
        didSet { saveKey(anthropicKey, service: Self.anthropicKeychainService) }
    }

    /// Optional Bearer token for local servers that require one.
    var localServerKey: String = "" {
        didSet { saveKey(localServerKey, service: Self.localServerKeychainService) }
    }

    private func saveKey(_ value: String, service: String) {
        if value.isEmpty {
            KeychainHelper.delete(service: service, account: Self.keychainAccount)
        } else {
            KeychainHelper.save(value, service: service, account: Self.keychainAccount)
        }
    }

    // MARK: - Stored Properties

    var recordingWindowStyle: RecordingWindowStyle = .mini {
        didSet { save(recordingWindowStyle, forKey: SettingsKey.recordingWindowStyle) }
    }

    var hotkeyBinding: HotkeyBinding = .defaultHotkey {
        didSet { save(hotkeyBinding, forKey: SettingsKey.hotkeyBinding) }
    }

    var cancelHotkeyBinding: HotkeyBinding? = nil {
        didSet { saveOptional(cancelHotkeyBinding, forKey: SettingsKey.cancelHotkeyBinding) }
    }

    var pushToTalkBinding: HotkeyBinding? = nil {
        didSet { saveOptional(pushToTalkBinding, forKey: SettingsKey.pushToTalkBinding) }
    }

    var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: SettingsKey.launchAtLogin) }
    }

    var autoMicVolume: Bool = true {
        didSet { defaults.set(autoMicVolume, forKey: SettingsKey.autoMicVolume) }
    }

    var silenceRemoval: Bool = true {
        didSet { defaults.set(silenceRemoval, forKey: SettingsKey.silenceRemoval) }
    }

    var soundEffectsEnabled: Bool = true {
        didSet { defaults.set(soundEffectsEnabled, forKey: SettingsKey.soundEffectsEnabled) }
    }

    var soundEffectsVolume: Double = 0.7 {
        didSet { defaults.set(soundEffectsVolume, forKey: SettingsKey.soundEffectsVolume) }
    }

    var selectedInputDeviceID: String? = nil {
        didSet { defaults.set(selectedInputDeviceID, forKey: SettingsKey.selectedInputDeviceID) }
    }

    var hasCompletedOnboarding: Bool = false {
        didSet { defaults.set(hasCompletedOnboarding, forKey: SettingsKey.hasCompletedOnboarding) }
    }

    var selectedModeID: UUID? = nil {
        didSet {
            if let id = selectedModeID {
                defaults.set(id.uuidString, forKey: SettingsKey.selectedModeID)
            } else {
                defaults.removeObject(forKey: SettingsKey.selectedModeID)
            }
        }
    }

    // MARK: - Persistence Helpers

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func saveOptional<T: Encodable>(_ value: T?, forKey key: String) {
        if let value = value, let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func loadAll() {
        // Refinement
        refinementEnabled = defaults.bool(forKey: SettingsKey.refinementEnabled)
        if let raw = defaults.string(forKey: SettingsKey.refinementProvider),
           let provider = RefinementProvider(rawValue: raw)
        {
            refinementProvider = provider
        }
        localServerBaseURL = defaults.string(forKey: SettingsKey.localServerBaseURL) ?? "http://localhost:11434/v1"
        localServerModel = defaults.string(forKey: SettingsKey.localServerModel) ?? ""
        openAIModel = defaults.string(forKey: SettingsKey.openAIModel) ?? "gpt-4o-mini"
        azureOpenAIEndpoint = defaults.string(forKey: SettingsKey.azureOpenAIEndpoint) ?? ""
        azureOpenAIDeployment = defaults.string(forKey: SettingsKey.azureOpenAIDeployment) ?? ""
        azureOpenAIAPIVersion = defaults.string(forKey: SettingsKey.azureOpenAIAPIVersion) ?? "2024-10-21"
        anthropicModel = defaults.string(forKey: SettingsKey.anthropicModel) ?? "claude-haiku-4-5"

        // Transcription
        if let raw = defaults.string(forKey: SettingsKey.transcriptionProvider),
           let provider = TranscriptionProviderChoice(rawValue: raw)
        {
            transcriptionProvider = provider
        }
        openAITranscriptionModel = defaults.string(forKey: SettingsKey.openAITranscriptionModel) ?? "whisper-1"
        azureWhisperDeployment = defaults.string(forKey: SettingsKey.azureWhisperDeployment) ?? ""

        // API keys
        openAIKey = KeychainHelper.load(service: Self.openAIKeychainService, account: Self.keychainAccount) ?? ""
        azureOpenAIKey = KeychainHelper.load(service: Self.azureKeychainService, account: Self.keychainAccount) ?? ""
        anthropicKey = KeychainHelper.load(service: Self.anthropicKeychainService, account: Self.keychainAccount) ?? ""
        localServerKey = KeychainHelper.load(service: Self.localServerKeychainService, account: Self.keychainAccount) ?? ""

        migrateLegacyEnhanceSettings()

        if let style = load(RecordingWindowStyle.self, forKey: SettingsKey.recordingWindowStyle) {
            recordingWindowStyle = style
        }

        if let binding = load(HotkeyBinding.self, forKey: SettingsKey.hotkeyBinding) {
            hotkeyBinding = binding
        }

        cancelHotkeyBinding = load(HotkeyBinding.self, forKey: SettingsKey.cancelHotkeyBinding)
        pushToTalkBinding = load(HotkeyBinding.self, forKey: SettingsKey.pushToTalkBinding)

        if defaults.object(forKey: SettingsKey.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: SettingsKey.launchAtLogin)
        }

        if defaults.object(forKey: SettingsKey.autoMicVolume) != nil {
            autoMicVolume = defaults.bool(forKey: SettingsKey.autoMicVolume)
        }

        if defaults.object(forKey: SettingsKey.silenceRemoval) != nil {
            silenceRemoval = defaults.bool(forKey: SettingsKey.silenceRemoval)
        }

        if defaults.object(forKey: SettingsKey.soundEffectsEnabled) != nil {
            soundEffectsEnabled = defaults.bool(forKey: SettingsKey.soundEffectsEnabled)
        }

        if defaults.object(forKey: SettingsKey.soundEffectsVolume) != nil {
            soundEffectsVolume = defaults.double(forKey: SettingsKey.soundEffectsVolume)
        }

        selectedInputDeviceID = defaults.string(forKey: SettingsKey.selectedInputDeviceID)

        if defaults.object(forKey: SettingsKey.hasCompletedOnboarding) != nil {
            hasCompletedOnboarding = defaults.bool(forKey: SettingsKey.hasCompletedOnboarding)
        }

        if let uuidString = defaults.string(forKey: SettingsKey.selectedModeID) {
            selectedModeID = UUID(uuidString: uuidString)
        }
    }

    /// One-time migration of the old enhance-mode configuration (which was
    /// Azure OpenAI) into the Azure refinement fields and Keychain service.
    private func migrateLegacyEnhanceSettings() {
        let legacyEndpoint = defaults.string(forKey: SettingsKey.enhanceEndpoint) ?? ""
        guard azureOpenAIEndpoint.isEmpty, !legacyEndpoint.isEmpty else { return }

        // Old UI suggested endpoints like ".../openai/v1"; the Azure client
        // appends its own path, so strip anything from "/openai" on.
        var endpoint = legacyEndpoint
        if let range = endpoint.range(of: "/openai") {
            endpoint = String(endpoint[..<range.lowerBound])
        }
        azureOpenAIEndpoint = endpoint
        azureOpenAIDeployment = defaults.string(forKey: SettingsKey.enhanceModel) ?? ""
        refinementProvider = .azureOpenAI

        if let legacyKey = KeychainHelper.load(service: Self.legacyKeychainService, account: Self.keychainAccount),
           !legacyKey.isEmpty
        {
            azureOpenAIKey = legacyKey
            KeychainHelper.delete(service: Self.legacyKeychainService, account: Self.keychainAccount)
        }

        defaults.removeObject(forKey: SettingsKey.enhanceEndpoint)
        defaults.removeObject(forKey: SettingsKey.enhanceModel)
    }
}
