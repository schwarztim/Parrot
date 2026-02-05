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
    static let enhanceEndpoint = "parrot.enhanceEndpoint"
    static let enhanceModel = "parrot.enhanceModel"
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

    private static let keychainService = "com.parrot.enhance"
    private static let keychainAccount = "apiKey"

    // MARK: - Enhance Mode Settings

    var enhanceEndpoint: String = "" {
        didSet { defaults.set(enhanceEndpoint, forKey: SettingsKey.enhanceEndpoint) }
    }

    var enhanceModel: String = "" {
        didSet { defaults.set(enhanceModel, forKey: SettingsKey.enhanceModel) }
    }

    /// The API key is stored in the macOS Keychain, not UserDefaults.
    var enhanceApiKey: String = "" {
        didSet {
            if enhanceApiKey.isEmpty {
                KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
            } else {
                KeychainHelper.save(enhanceApiKey, service: Self.keychainService, account: Self.keychainAccount)
            }
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
        // Enhance Mode
        enhanceEndpoint = defaults.string(forKey: SettingsKey.enhanceEndpoint) ?? ""
        enhanceModel = defaults.string(forKey: SettingsKey.enhanceModel) ?? ""
        enhanceApiKey = KeychainHelper.load(
            service: Self.keychainService,
            account: Self.keychainAccount
        ) ?? ""

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
}
