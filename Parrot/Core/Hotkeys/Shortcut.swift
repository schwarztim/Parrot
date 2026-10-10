import AppKit
import Foundation

/// One saved binding for a named shortcut: a key with modifiers, a lone
/// modifier key (Right Command, Fn, Caps Lock), or mouse buttons. [TRG]
///
/// Stored as JSON under `parrot.hotkeys.<name>`. A lone modifier keeps only
/// its own key code (left and right come from the key code), so its
/// `modifiers` are always empty. An empty shortcut (no key, no mouse button)
/// means "removed".
struct Shortcut: Hashable, Sendable {
    /// macOS virtual key code. Nil for a mouse binding or an empty shortcut.
    var keyCode: Int?
    /// Raw `NSEvent.ModifierFlags`, limited to Control, Option, Shift and Command.
    var modifiers: UInt
    /// Mouse button numbers as `NSEvent.buttonNumber` reports them
    /// (2 is the scroll wheel click). Empty for keys.
    var mouseButtons: [Int]
    /// Fires on a second tap inside the double-tap window instead of on the
    /// first press.
    var doubleTap: Bool

    /// Normalizes on the way in: device-specific modifier bits are dropped, a
    /// lone modifier loses its own (and any other) modifier bits, and a mouse
    /// binding has no key.
    init(keyCode: Int?, modifiers: NSEvent.ModifierFlags = [], mouseButtons: [Int] = [], doubleTap: Bool = false) {
        let buttons = Array(Set(mouseButtons)).sorted()
        if !buttons.isEmpty {
            self.keyCode = nil
            self.modifiers = 0
        } else if let keyCode, Self.loneModifierKeyCodes.contains(keyCode) {
            self.keyCode = keyCode
            self.modifiers = 0
        } else {
            self.keyCode = keyCode
            self.modifiers = keyCode == nil ? 0 : modifiers.intersection(Self.supportedModifiers).rawValue
        }
        self.mouseButtons = buttons
        self.doubleTap = doubleTap
    }

    /// A key, or a lone modifier key, with optional modifiers.
    static func key(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// A mouse button binding.
    static func mouse(_ buttonNumber: Int) -> Shortcut {
        Shortcut(keyCode: nil, mouseButtons: [buttonNumber])
    }

    /// No binding. Stored to mean "removed by the user".
    static let none = Shortcut(keyCode: nil)

    // MARK: - Key Codes

    static let functionKeyCode = 0x3F
    static let capsLockKeyCode = 0x39
    static let escapeKeyCode = 0x35

    /// Keys that can be bound alone: both Command, Shift, Option and Control
    /// keys, Fn/Globe and Caps Lock.
    static let loneModifierKeyCodes: Set<Int> = [
        0x37, 0x36, // Left/Right Command
        0x38, 0x3C, // Left/Right Shift
        0x3A, 0x3D, // Left/Right Option
        0x3B, 0x3E, // Left/Right Control
        0x3F,       // Fn/Globe
        0x39,       // Caps Lock
    ]

    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    // MARK: - Properties

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var isEmpty: Bool { keyCode == nil && mouseButtons.isEmpty }
    var isMouse: Bool { !mouseButtons.isEmpty }
    var isModifierOnly: Bool { keyCode.map { Self.loneModifierKeyCodes.contains($0) } ?? false }

    /// True when both fire on the same physical input: the same key and
    /// modifiers, or a shared mouse button. Double-tap is not compared,
    /// since a double tap also presses the key once.
    func overlaps(_ other: Shortcut) -> Bool {
        if isMouse || other.isMouse {
            return !Set(mouseButtons).isDisjoint(with: other.mouseButtons)
        }
        guard let keyCode, let otherKey = other.keyCode else { return false }
        return keyCode == otherKey && modifiers == other.modifiers
    }

    // MARK: - Display

    /// One string per key cap, modifiers first in macOS order, for example
    /// `["⌥", "Space"]`, `["Right ⌘"]`, `["fn"]` or `["Scroll Wheel Click"]`.
    /// Empty for an empty shortcut.
    var keycaps: [String] {
        if let button = mouseButtons.first {
            return [Self.mouseButtonName(button)]
        }
        guard let keyCode else { return [] }
        if isModifierOnly {
            return [Self.loneModifierCap(keyCode)]
        }
        var caps: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { caps.append("⌃") }
        if flags.contains(.option) { caps.append("⌥") }
        if flags.contains(.shift) { caps.append("⇧") }
        if flags.contains(.command) { caps.append("⌘") }
        caps.append(Self.keyName(keyCode))
        return caps
    }

    /// A one-line label, for example "⌥Space", "Right Option", "Fn",
    /// "Double-tap Fn" or "Scroll Wheel Click". "None" when empty.
    var displayName: String {
        if let button = mouseButtons.first {
            return Self.mouseButtonName(button)
        }
        guard let keyCode else { return "None" }
        let base = isModifierOnly ? Self.loneModifierName(keyCode) : keycaps.joined()
        return doubleTap ? "Double-tap \(base)" : base
    }

    static func mouseButtonName(_ button: Int) -> String {
        button == 2 ? "Scroll Wheel Click" : "Mouse Button \(button + 1)"
    }

    static func loneModifierName(_ keyCode: Int) -> String {
        switch keyCode {
        case 0x3A: return "Left Option"
        case 0x3D: return "Right Option"
        case 0x37: return "Left Command"
        case 0x36: return "Right Command"
        case 0x38: return "Left Shift"
        case 0x3C: return "Right Shift"
        case 0x3B: return "Left Control"
        case 0x3E: return "Right Control"
        case 0x3F: return "Fn"
        case 0x39: return "Caps Lock"
        default: return "Modifier"
        }
    }

    static func loneModifierCap(_ keyCode: Int) -> String {
        switch keyCode {
        case 0x3A: return "Left ⌥"
        case 0x3D: return "Right ⌥"
        case 0x37: return "Left ⌘"
        case 0x36: return "Right ⌘"
        case 0x38: return "Left ⇧"
        case 0x3C: return "Right ⇧"
        case 0x3B: return "Left ⌃"
        case 0x3E: return "Right ⌃"
        case 0x3F: return "fn"
        case 0x39: return "Caps Lock"
        default: return "Modifier"
        }
    }

    /// Name of a non-modifier key on a US keyboard layout.
    static func keyName(_ keyCode: Int) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "Clear", 0x4B: "Keypad /",
        0x4C: "Enter", 0x4E: "Keypad -", 0x51: "Keypad =", 0x52: "Keypad 0", 0x53: "Keypad 1",
        0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4", 0x57: "Keypad 5", 0x58: "Keypad 6",
        0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x72: "Help", 0x73: "Home", 0x74: "Page Up", 0x75: "⌦", 0x77: "End", 0x79: "Page Down",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
}

// MARK: - Codable

extension Shortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, mouseButtons, doubleTap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try c.decodeIfPresent(Int.self, forKey: .keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: try c.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0),
            mouseButtons: try c.decodeIfPresent([Int].self, forKey: .mouseButtons) ?? [],
            doubleTap: try c.decodeIfPresent(Bool.self, forKey: .doubleTap) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(keyCode, forKey: .keyCode)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(mouseButtons, forKey: .mouseButtons)
        if doubleTap { try c.encode(true, forKey: .doubleTap) }
    }
}

// MARK: - Conversions

extension Shortcut {
    /// Converts a saved `HotkeyBinding`. Nil for the broken keyCode 0
    /// keyboard binding an old capture bug saved (the listener ignored it and
    /// used Right Option), and for "None".
    init?(legacy binding: HotkeyBinding) {
        if let button = binding.mouseButton {
            self = .mouse(button)
            return
        }
        guard binding.keyCode != 0 else { return nil }
        self.init(keyCode: Int(binding.keyCode), modifiers: binding.modifiers)
    }

    /// The `HotkeyBinding` form older views and onboarding read. Nil when
    /// empty. A binding with several mouse buttons keeps the first.
    var legacyBinding: HotkeyBinding? {
        if let button = mouseButtons.first {
            return HotkeyBinding(keyCode: 0, modifiers: [], displayName: displayName, mouseButton: button)
        }
        guard let keyCode else { return nil }
        return HotkeyBinding(keyCode: UInt16(keyCode), modifiers: modifierFlags, displayName: displayName)
    }

    /// Converts a mode's shortcut.
    init(mode shortcut: ModeShortcut) {
        if let button = shortcut.mouseButton {
            self = .mouse(button)
        } else {
            self.init(keyCode: shortcut.keyCode, modifiers: NSEvent.ModifierFlags(rawValue: shortcut.modifiers))
        }
    }

    /// The form stored on `Mode.shortcut`. Nil when empty.
    var modeShortcut: ModeShortcut? {
        if let button = mouseButtons.first {
            return ModeShortcut(keyCode: 0, modifiers: 0, mouseButton: button)
        }
        guard let keyCode else { return nil }
        return ModeShortcut(keyCode: keyCode, modifiers: modifiers)
    }
}

// MARK: - Superwhisper

/// Reads Superwhisper's saved shortcuts for the importer. [TRG, used by DATA]
///
/// Superwhisper keeps one UserDefaults key per shortcut,
/// `KeyboardShortcuts_<name>`, holding a JSON string
/// `{"carbonKeyCode": Int, "carbonModifiers": Int, "mouseButtonNumbers": [Int]}`.
/// A lone modifier is stored as that key's own key code plus its own
/// modifier bit (`{"carbonKeyCode":54,"carbonModifiers":256}` is Right
/// Command alone). A mode's `shortcut` object has the same two key fields
/// and no mouse buttons.
enum SuperwhisperShortcut {

    /// Prefix of every Superwhisper shortcut key in its defaults domain.
    static let defaultsKeyPrefix = "KeyboardShortcuts_"

    /// The JSON object, decodable on its own or inside a mode file.
    struct Payload: Codable, Hashable, Sendable {
        var carbonKeyCode: Int?
        var carbonModifiers: Int?
        var mouseButtonNumbers: [Int]?

        /// The Parrot shortcut. `.none` when the payload binds nothing.
        var shortcut: Shortcut {
            SuperwhisperShortcut.shortcut(
                carbonKeyCode: carbonKeyCode ?? 0,
                carbonModifiers: carbonModifiers ?? 0,
                mouseButtonNumbers: mouseButtonNumbers ?? []
            )
        }

        /// The form stored on `Mode.shortcut`. Nil when it binds nothing.
        var modeShortcut: ModeShortcut? { shortcut.modeShortcut }
    }

    // Carbon modifier masks (Events.h).
    private static let cmdKey = 256
    private static let shiftKey = 512
    private static let alphaLock = 1024
    private static let optionKey = 2048
    private static let controlKey = 4096
    private static let rightShiftKey = 8192
    private static let rightOptionKey = 16384
    private static let rightControlKey = 32768

    /// Converts the decoded fields. Mouse buttons win over the key. Key code
    /// 0 with no modifiers and no mouse button reads as "nothing bound"
    /// rather than a bare A key.
    static func shortcut(carbonKeyCode: Int, carbonModifiers: Int, mouseButtonNumbers: [Int] = []) -> Shortcut {
        if !mouseButtonNumbers.isEmpty {
            return Shortcut(keyCode: nil, mouseButtons: mouseButtonNumbers)
        }
        guard carbonKeyCode > 0 || carbonModifiers != 0 else { return .none }
        return Shortcut(keyCode: carbonKeyCode, modifiers: modifierFlags(carbon: carbonModifiers))
    }

    /// Decodes the JSON string Superwhisper stores. Nil when unreadable.
    static func shortcut(fromJSON json: String) -> Shortcut? {
        shortcut(fromJSON: Data(json.utf8))
    }

    static func shortcut(fromJSON data: Data) -> Shortcut? {
        (try? JSONDecoder().decode(Payload.self, from: data))?.shortcut
    }

    /// Decodes a raw value read from Superwhisper's defaults: a JSON string
    /// or data, or `false` for a shortcut the user turned off (`.none`).
    static func shortcut(fromDefaultsValue value: Any) -> Shortcut? {
        switch value {
        case let string as String: return shortcut(fromJSON: string)
        case let data as Data: return shortcut(fromJSON: data)
        case let flag as Bool where flag == false: return Shortcut.none
        default: return nil
        }
    }

    /// Decodes a mode's `shortcut` JSON object into `Mode.shortcut`.
    static func modeShortcut(fromJSON data: Data) -> ModeShortcut? {
        (try? JSONDecoder().decode(Payload.self, from: data))?.modeShortcut
    }

    static func modeShortcut(carbonKeyCode: Int, carbonModifiers: Int) -> ModeShortcut? {
        shortcut(carbonKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers).modeShortcut
    }

    /// The Parrot name for a Superwhisper defaults key such as
    /// `KeyboardShortcuts_pushToTalk`. Nil for other keys.
    static func shortcutName(forDefaultsKey key: String) -> ShortcutName? {
        guard key.hasPrefix(defaultsKeyPrefix) else { return nil }
        return ShortcutName(rawValue: String(key.dropFirst(defaultsKeyPrefix.count)))
    }

    /// Carbon modifier mask to `NSEvent.ModifierFlags`. Right-side Carbon
    /// bits map to the plain modifier.
    static func modifierFlags(carbon: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & cmdKey != 0 { flags.insert(.command) }
        if carbon & (shiftKey | rightShiftKey) != 0 { flags.insert(.shift) }
        if carbon & alphaLock != 0 { flags.insert(.capsLock) }
        if carbon & (optionKey | rightOptionKey) != 0 { flags.insert(.option) }
        if carbon & (controlKey | rightControlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// `NSEvent.ModifierFlags` to a Carbon modifier mask, for registering
    /// key combos as system hot keys.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        return carbon
    }
}
