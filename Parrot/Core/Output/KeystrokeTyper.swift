import CoreGraphics
import Foundation

// MARK: - US QWERTY

/// The key and Shift state that type each character on a US QWERTY
/// keyboard. Simulated typing supports only this layout. [OUT]
enum USQwerty {
    struct Key: Equatable, Sendable {
        let code: CGKeyCode
        let shift: Bool
    }

    static let returnKey: CGKeyCode = 36
    static let tabKey: CGKeyCode = 48

    /// The key for `character`, or nil when US QWERTY has no key for it.
    static func key(for character: Character) -> Key? {
        table[character]
    }

    private static let table: [Character: Key] = {
        var table: [Character: Key] = [:]
        let letters: [(Character, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (letter, code) in letters {
            table[letter] = Key(code: code, shift: false)
            table[Character(letter.uppercased())] = Key(code: code, shift: true)
        }
        // Unshifted and shifted symbol on each remaining key.
        let pairs: [(Character, Character, CGKeyCode)] = [
            ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21), ("6", "^", 22),
            ("5", "%", 23), ("=", "+", 24), ("9", "(", 25), ("7", "&", 26), ("-", "_", 27),
            ("8", "*", 28), ("0", ")", 29), ("]", "}", 30), ("[", "{", 33), ("'", "\"", 39),
            (";", ":", 41), ("\\", "|", 42), (",", "<", 43), ("/", "?", 44), (".", ">", 47),
            ("`", "~", 50),
        ]
        for (plain, shifted, code) in pairs {
            table[plain] = Key(code: code, shift: false)
            table[shifted] = Key(code: code, shift: true)
        }
        table[" "] = Key(code: 49, shift: false)
        table["\t"] = Key(code: tabKey, shift: false)
        table["\n"] = Key(code: returnKey, shift: false)
        table["\r"] = Key(code: returnKey, shift: false)
        table["\r\n"] = Key(code: returnKey, shift: false)
        return table
    }()
}

// MARK: - Key Events

/// Posts synthetic key events to the HID event tap. Needs Accessibility.
enum KeyEvents {
    /// One key press (down and up) with exactly `flags` held, so a key the
    /// user is still holding (Shift for auto-submit) does not leak in.
    static func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Types a character with no US QWERTY key (accents, emoji, dashes) as a
    /// Unicode string on a key event, so it is not dropped.
    static func typeUnicode(_ character: Character) {
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - KeystrokeTyper

/// Types text as key presses instead of pasting, so it streams from the
/// cursor. Experimental: mapped for US QWERTY. [OUT]
struct KeystrokeTyper: Sendable {
    /// Pause between characters; some apps drop events posted back to back.
    var interKeyDelay: TimeInterval = 0.004

    init(interKeyDelay: TimeInterval = 0.004) {
        self.interKeyDelay = interKeyDelay
    }

    /// Posts one key press per character, off the main thread.
    func type(_ text: String) async {
        let delay = UInt64(interKeyDelay * 1_000_000_000)
        for character in text {
            if let key = USQwerty.key(for: character) {
                KeyEvents.press(key.code, flags: key.shift ? .maskShift : [])
            } else {
                KeyEvents.typeUnicode(character)
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }
}
