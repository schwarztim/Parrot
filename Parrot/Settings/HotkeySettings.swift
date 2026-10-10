import AppKit
import CoreGraphics
import Foundation
import Observation

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

// MARK: - HotkeySettings

/// Global shortcut bindings. [TRG]
@Observable
final class HotkeySettings {

    private enum Key {
        static let hotkeyBinding = "parrot.hotkeyBinding"
        static let cancelHotkeyBinding = "parrot.cancelHotkeyBinding"
        static let pushToTalkBinding = "parrot.pushToTalkBinding"
    }

    /// The dictation hotkey (hold to talk).
    var hotkeyBinding: HotkeyBinding {
        didSet { store.setEncoded(hotkeyBinding, forKey: Key.hotkeyBinding) }
    }

    var cancelHotkeyBinding: HotkeyBinding? {
        didSet { store.setEncoded(cancelHotkeyBinding, forKey: Key.cancelHotkeyBinding) }
    }

    var pushToTalkBinding: HotkeyBinding? {
        didSet { store.setEncoded(pushToTalkBinding, forKey: Key.pushToTalkBinding) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        hotkeyBinding = store.decoded(HotkeyBinding.self, forKey: Key.hotkeyBinding) ?? .defaultHotkey
        cancelHotkeyBinding = store.decoded(HotkeyBinding.self, forKey: Key.cancelHotkeyBinding)
        pushToTalkBinding = store.decoded(HotkeyBinding.self, forKey: Key.pushToTalkBinding)
        self.store = store
    }
}
