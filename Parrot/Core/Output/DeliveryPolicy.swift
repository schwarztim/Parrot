import Foundation

// MARK: - DeliveryPolicy

/// How a finished dictation is delivered, decided from the settings, the
/// mode and the moment of stop. Pure, so the rules are unit tested. [OUT]
struct DeliveryPolicy: Equatable {

    enum Method: Equatable {
        /// Paste through the clipboard (menu action, else Cmd+V).
        case paste
        /// Simulate key presses.
        case type
        /// Leave the text on the clipboard only.
        case clipboardOnly(ClipboardOnlyReason)
    }

    enum ClipboardOnlyReason: Equatable {
        /// Auto-paste is off for this mode or globally.
        case autoPasteOff
        /// Accessibility is not granted, so no keystroke can be posted.
        case untrusted
    }

    let method: Method
    /// Press Return after the paste (Shift held at stop with auto-submit on).
    let pressReturn: Bool
    /// Seconds until the user's own clipboard goes back; nil leaves the
    /// dictation on the clipboard.
    let restoreDelay: TimeInterval?
    /// Mark the dictation so clipboard history apps skip it.
    let markTransient: Bool

    /// True when the text is actually pasted or typed.
    var delivers: Bool {
        if case .clipboardOnly = method { return false }
        return true
    }

    /// The mode's override when set, otherwise the global switch.
    static func effectiveAutoPaste(mode: Bool?, global: Bool) -> Bool {
        mode ?? global
    }

    init(
        modeAutoPaste: Bool?,
        globalAutoPaste: Bool,
        simulateKeypresses: Bool,
        accessibilityTrusted: Bool,
        shiftHeldAtStop: Bool,
        autoSubmitWithShift: Bool,
        clipboardBehaviour: ClipboardBehaviour,
        restoreDelay: TimeInterval,
        clipboardHistory: Bool
    ) {
        if !Self.effectiveAutoPaste(mode: modeAutoPaste, global: globalAutoPaste) {
            method = .clipboardOnly(.autoPasteOff)
        } else if !accessibilityTrusted {
            method = .clipboardOnly(.untrusted)
        } else {
            method = simulateKeypresses ? .type : .paste
        }

        let delivers: Bool
        if case .clipboardOnly = method { delivers = false } else { delivers = true }

        pressReturn = delivers && autoSubmitWithShift && shiftHeldAtStop
        markTransient = !clipboardHistory
        if delivers && clipboardBehaviour == .keep {
            // Typed text never reads the clipboard, so it goes back at once.
            self.restoreDelay = method == .type ? 0 : max(0, restoreDelay)
        } else {
            self.restoreDelay = nil
        }
    }

    /// The policy for a dictation in `mode`. Missing settings read as the
    /// defaults.
    @MainActor
    init(settings: OutputSettings?, mode: Mode?, shiftHeldAtStop: Bool, accessibilityTrusted: Bool) {
        self.init(
            modeAutoPaste: mode?.autoPaste,
            globalAutoPaste: settings?.autoPaste ?? true,
            simulateKeypresses: settings?.simulateKeypresses ?? false,
            accessibilityTrusted: accessibilityTrusted,
            shiftHeldAtStop: shiftHeldAtStop,
            autoSubmitWithShift: settings?.autoSubmitWithShift ?? false,
            clipboardBehaviour: settings?.clipboardBehaviour ?? .keep,
            restoreDelay: settings?.restoreDelay ?? 1.0,
            clipboardHistory: settings?.clipboardHistory ?? false
        )
    }
}

// MARK: - PasteConfirmation

/// What the focused field showed after a paste. [OUT]
enum PasteConfirmation: Equatable, Sendable {
    /// The field's value changed.
    case confirmed
    /// Focus moved to another element; the text likely landed there.
    case redirected
    /// The field reads back unchanged.
    case unconfirmed
    /// The field could not be read; treat the paste as done.
    case unavailable

    /// Compares the field before the paste with what is focused now.
    static func evaluate(before: FieldSnapshot?, after: FieldSnapshot?, sameElement: Bool) -> PasteConfirmation {
        guard let before, let after,
              let beforeLength = before.valueLength, let afterLength = after.valueLength
        else { return .unavailable }
        guard sameElement else { return .redirected }
        if beforeLength != afterLength || before.valueHash != after.valueHash {
            return .confirmed
        }
        return .unconfirmed
    }
}

/// The focused element's shape, without keeping its text. [OUT]
struct FieldSnapshot: Equatable, Sendable {
    var role: String?
    var isEditable: Bool
    var isSecure: Bool
    /// UTF-16 length of the value; nil when it could not be read.
    var valueLength: Int?
    /// Hash of the value, to spot a change of the same length.
    var valueHash: Int?

    init(role: String? = nil, isEditable: Bool = false, isSecure: Bool = false, value: String? = nil) {
        self.role = role
        self.isEditable = isEditable
        self.isSecure = isSecure
        self.valueLength = value.map { ($0 as NSString).length }
        self.valueHash = value?.hashValue
    }
}
