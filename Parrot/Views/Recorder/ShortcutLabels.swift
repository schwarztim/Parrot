import Foundation

/// The saved shortcuts as keycap labels, for Home's quick start and the
/// recorder's bottom bar. [UI]
///
/// The one place UI reads hotkey names, so richer keycap strings from TRG
/// can replace `displayName` here without touching the views.
struct ShortcutLabels: Equatable {

    /// One quick start line: the keycap and what it does.
    struct Row: Equatable, Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    /// The dictation hotkey. Nil when it is unset.
    var dictation: String?
    /// The separate push-to-talk key, when one is set.
    var pushToTalk: String?
    /// The cancel key ("Esc" unless rebound).
    var cancel: String

    init(dictation: String?, pushToTalk: String?, cancel: String) {
        self.dictation = dictation
        self.pushToTalk = pushToTalk
        self.cancel = cancel
    }

    init(hotkeys: HotkeySettings) {
        self.init(
            dictation: Self.label(hotkeys.hotkeyBinding),
            pushToTalk: hotkeys.pushToTalkBinding.flatMap(Self.label),
            cancel: hotkeys.cancelHotkeyBinding.flatMap(Self.label) ?? "Esc"
        )
    }

    /// The quick start lines, only for keys that are bound.
    var quickStartRows: [Row] {
        var rows: [Row] = []
        if let dictation {
            rows.append(Row(keys: dictation, action: "Hold to talk, release to paste"))
        }
        if let pushToTalk, pushToTalk != dictation {
            rows.append(Row(keys: pushToTalk, action: "Push to talk (hold)"))
        }
        rows.append(Row(keys: cancel, action: "Cancel recording"))
        return rows
    }

    /// A binding's keycap text, or nil for an empty binding.
    static func label(_ binding: HotkeyBinding) -> String? {
        let name = binding.displayName.trimmingCharacters(in: .whitespaces)
        let isEmpty = binding.mouseButton == nil && binding.keyCode == 0
        if isEmpty || name.isEmpty || name == HotkeyBinding.empty.displayName {
            return nil
        }
        return name
    }
}
