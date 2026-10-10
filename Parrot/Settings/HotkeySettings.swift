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
///
/// The named shortcuts (`ShortcutName`) are saved one JSON value per name
/// under `parrot.hotkeys.<name>`; a missing value means the built-in
/// default. `hotkeyBinding` is the pre-registry key and mirrors Push to Talk
/// both ways, so older readers (onboarding) always show the live key.
@Observable
final class HotkeySettings {

    private enum Key {
        static let hotkeyBinding = "parrot.hotkeyBinding"
        static let cancelHotkeyBinding = "parrot.cancelHotkeyBinding"
        static let pushToTalkBinding = "parrot.pushToTalkBinding"
        static let migrated = "parrot.hotkeys.migrated"
    }

    /// The dictation hotkey from before the registry; mirrors Push to Talk.
    var hotkeyBinding: HotkeyBinding {
        didSet {
            store.setEncoded(hotkeyBinding, forKey: Key.hotkeyBinding)
            let mirrored = Shortcut(legacy: hotkeyBinding) ?? .none
            if !Self.sameInput(mirrored, shortcut(for: .pushToTalk)) {
                setShortcut(mirrored, for: .pushToTalk)
            }
        }
    }

    var cancelHotkeyBinding: HotkeyBinding? {
        didSet { store.setEncoded(cancelHotkeyBinding, forKey: Key.cancelHotkeyBinding) }
    }

    /// Saved by an older recorder that nothing listened to. Kept for reading.
    var pushToTalkBinding: HotkeyBinding? {
        didSet { store.setEncoded(pushToTalkBinding, forKey: Key.pushToTalkBinding) }
    }

    /// True once the pre-registry bindings were carried over (see
    /// `migrateIfNeeded(hasCompletedOnboarding:)`).
    var migrated: Bool {
        didSet { store.set(migrated, forKey: Key.migrated) }
    }

    /// Saved bindings by name. Names without an entry use their default.
    private(set) var savedShortcuts: [ShortcutName: Shortcut]

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        hotkeyBinding = store.decoded(HotkeyBinding.self, forKey: Key.hotkeyBinding) ?? .defaultHotkey
        cancelHotkeyBinding = store.decoded(HotkeyBinding.self, forKey: Key.cancelHotkeyBinding)
        pushToTalkBinding = store.decoded(HotkeyBinding.self, forKey: Key.pushToTalkBinding)
        migrated = store.bool(Key.migrated, default: false)
        var saved: [ShortcutName: Shortcut] = [:]
        for name in ShortcutName.allCases {
            if let shortcut = store.decoded(Shortcut.self, forKey: name.defaultsKey) {
                saved[name] = shortcut
            }
        }
        savedShortcuts = saved
        self.store = store
    }

    // MARK: - Named Shortcuts

    /// The binding in effect for `name`: the saved one, else (before
    /// migration) the pre-registry key, else the default. `.none` when removed.
    func shortcut(for name: ShortcutName) -> Shortcut {
        if let saved = savedShortcuts[name] { return saved }
        if !migrated, let legacy = legacyShortcut(for: name) { return legacy }
        return name.defaultShortcut
    }

    /// Every name's binding in effect.
    var allShortcuts: [ShortcutName: Shortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutName.allCases.map { ($0, shortcut(for: $0)) })
    }

    /// Saves a binding. Pass `.none` to remove it.
    func setShortcut(_ shortcut: Shortcut, for name: ShortcutName) {
        savedShortcuts[name] = shortcut
        store.setEncoded(shortcut, forKey: name.defaultsKey)
        if name == .pushToTalk { mirrorToLegacy(shortcut) }
    }

    /// Goes back to the built-in default.
    func resetShortcut(_ name: ShortcutName) {
        savedShortcuts[name] = nil
        store.remove(name.defaultsKey)
        if name == .pushToTalk { mirrorToLegacy(name.defaultShortcut) }
    }

    /// True when `name` uses its built-in default.
    func isDefault(_ name: ShortcutName) -> Bool {
        shortcut(for: name) == name.defaultShortcut
    }

    // MARK: - Migration

    /// Carries the pre-registry bindings over once. Runs at setup, never in
    /// init. Existing installs (onboarding finished, or any old binding
    /// saved) keep their push-to-talk key and cancel key, and do not gain
    /// the new global Toggle Recording and Change Mode keys they never
    /// chose. Fresh installs keep every default.
    func migrateIfNeeded(hasCompletedOnboarding: Bool) {
        guard !migrated else { return }
        let existingInstall = hasCompletedOnboarding
            || store.contains(Key.hotkeyBinding)
            || store.contains(Key.cancelHotkeyBinding)
            || store.contains(Key.pushToTalkBinding)
        if existingInstall {
            for name in [ShortcutName.pushToTalk, .cancelRecording] where savedShortcuts[name] == nil {
                if let legacy = legacyShortcut(for: name) { setShortcut(legacy, for: name) }
            }
            for name in [ShortcutName.toggleRecording, .changeMode] where savedShortcuts[name] == nil {
                setShortcut(.none, for: name)
            }
        }
        migrated = true
    }

    /// The pre-registry binding for `name`, when one was saved and usable.
    private func legacyShortcut(for name: ShortcutName) -> Shortcut? {
        switch name {
        case .pushToTalk:
            guard store.contains(Key.hotkeyBinding) else { return nil }
            return Shortcut(legacy: hotkeyBinding)
        case .cancelRecording:
            return cancelHotkeyBinding.flatMap { Shortcut(legacy: $0) }
        default:
            return nil
        }
    }

    private func mirrorToLegacy(_ shortcut: Shortcut) {
        let legacy = shortcut.legacyBinding ?? .empty
        if !Self.sameInput(Shortcut(legacy: legacy) ?? .none, Shortcut(legacy: hotkeyBinding) ?? .none) {
            hotkeyBinding = legacy
        }
    }

    /// Same physical input, ignoring double-tap and extra mouse buttons the
    /// legacy form cannot hold. Stops the two-way mirror from looping.
    private static func sameInput(_ a: Shortcut, _ b: Shortcut) -> Bool {
        (a.isEmpty && b.isEmpty) || a.overlaps(b)
    }
}
