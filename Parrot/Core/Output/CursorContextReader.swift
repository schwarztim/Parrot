import AppKit
import ApplicationServices

/// The focused element at one moment: where the paste will land. [OUT]
struct PasteTarget: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let field: FieldSnapshot
    /// Text around the caret; nil when the field cannot be read (secure
    /// fields included), in which case the text is inserted unchanged.
    let cursor: CursorContext?
}

/// Reads the focused element and the text around its caret through
/// Accessibility. OUT's own reader; ContextSnapshotter belongs to LLM.
///
/// Every call blocks on the target app, so call it off the main thread.
/// Each read is capped by a short messaging timeout, so a hung app costs at
/// most that long.
enum CursorContextReader {

    static let messagingTimeout: Float = 0.25

    /// The focused element with its caret context, or nil when nothing is
    /// focused or Accessibility is not granted.
    static func read() -> PasteTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = element(systemWide, kAXFocusedUIElementAttribute) else {
            diagLog("[Parrot:Output] No paste target element")
            return nil
        }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
        var settable: DarwinBoolean = false
        let isEditable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        if !isEditable {
            diagLog("[Parrot:Output] Paste target is not an input field (role \(role ?? "unknown"))")
        }

        // Never read a password field's text.
        let value = isSecure ? nil : string(element, kAXValueAttribute)
        let field = FieldSnapshot(role: role, isEditable: isEditable, isSecure: isSecure, value: value)

        var cursor: CursorContext?
        if let value, let selection = selectedRange(element) {
            cursor = CursorContext(text: value, selection: selection)
        }
        if cursor == nil {
            diagLog("[Parrot:Output] No cursor context before paste")
        }
        return PasteTarget(element: element, pid: pid, field: field, cursor: cursor)
    }

    /// The focused element's shape now, for paste confirmation.
    static func focusedField() -> (element: AXUIElement, field: FieldSnapshot)? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = element(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
        let value = isSecure ? nil : string(element, kAXValueAttribute)
        return (element, FieldSnapshot(role: role, isEditable: true, isSecure: isSecure, value: value))
    }

    // MARK: - Accessibility Reads

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
