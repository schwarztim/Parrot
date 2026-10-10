import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Finds which physical key types a character on the current keyboard
/// layout, so Cmd+V works on Dvorak, AZERTY and similar layouts. [OUT]
enum KeyboardLayout {

    /// `kVK_ANSI_V`, the QWERTY position. Used when no layout has a "v".
    static let ansiV: CGKeyCode = 0x09

    /// The key that types `character` in `map` (key code to the character it
    /// types), ignoring case, or nil. The lowest key code wins a tie.
    static func keyCode(for character: Character, in map: [CGKeyCode: Character]) -> CGKeyCode? {
        let target = String(character).lowercased()
        return map.filter { String($0.value).lowercased() == target }.keys.min()
    }

    /// The key code for Cmd+V: the current layout first, then the current
    /// ASCII-capable layout (for Cyrillic, Greek and the like), then QWERTY.
    /// Main thread only (Text Input Sources).
    @MainActor
    static func pasteKeyCode() -> CGKeyCode {
        if let code = keyCode(for: "v", in: commandMap(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())) {
            return code
        }
        if let code = keyCode(for: "v", in: commandMap(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())) {
            return code
        }
        return ansiV
    }

    /// What each key types with Command held on `source`. Command matters:
    /// "Dvorak - QWERTY Cmd" switches to QWERTY positions under Command.
    private static func commandMap(_ source: TISInputSource?) -> [CGKeyCode: Character] {
        guard let source,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let modifiers = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())

        var map: [CGKeyCode: Character] = [:]
        layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), modifiers, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length > 0,
                      let character = String(utf16CodeUnits: chars, count: length).first
                else { continue }
                map[CGKeyCode(code)] = character
            }
        }
        return map
    }
}
