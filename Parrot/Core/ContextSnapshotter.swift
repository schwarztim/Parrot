import AppKit
import ApplicationServices

/// Captures a `DictationContext` from the frontmost app and its focused text
/// field via the Accessibility API. Accessibility is already granted for paste,
/// so this needs no new permission.
///
/// Capture is best-effort and bounded: it uses a short AX messaging timeout so
/// an unresponsive target app cannot stall dictation, and it reads nothing from
/// secure (password) fields.
enum ContextSnapshotter {

    /// Maximum characters of selected text to capture.
    private static let maxContextChars = 1200
    /// Characters kept before and after the caret.
    private static let maxBeforeCaret = 800
    private static let maxAfterCaret = 300
    /// AX messaging timeout so a hung target app cannot block the hotkey path.
    private static let messagingTimeout: Float = 0.1

    /// Captures the current destination context. Returns an empty context when
    /// Accessibility is unavailable or nothing is focused.
    static func capture() -> DictationContext {
        var context = DictationContext()

        if let app = NSWorkspace.shared.frontmostApplication {
            context.appName = app.localizedName
            context.bundleID = app.bundleIdentifier
        }

        guard AXIsProcessTrusted() else { return context }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        guard let focused = element(systemWide, kAXFocusedUIElementAttribute) else {
            return context
        }

        let role = string(focused, kAXRoleAttribute)
        let subrole = string(focused, kAXSubroleAttribute)
        context.fieldRole = subrole ?? role

        // Never read content from a secure field.
        if subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" {
            context.isSecureField = true
            return context
        }

        context.fieldLabel = string(focused, kAXTitleAttribute)
            ?? string(focused, "AXPlaceholderValue")
            ?? string(focused, kAXDescriptionAttribute)

        // Native fields expose the selection directly; web content only
        // through text markers.
        context.selectedText = trimmed(string(focused, kAXSelectedTextAttribute))
            ?? trimmed(webSelection(focused))

        if let value = string(focused, kAXValueAttribute) {
            context.isEmptyField = value.isEmpty
            let (before, after) = textAroundCaret(value, range: selectedRange(focused))
            context.textBeforeCursor = before
            context.textAfterCursor = after
        }

        return context
    }

    /// The text just before and after the caret (or selection). Without a
    /// selected range, the end of the field stands in for the caret.
    static func textAroundCaret(_ value: String, range: NSRange?) -> (before: String?, after: String?) {
        let text = value as NSString
        let location = min(max(range?.location ?? text.length, 0), text.length)
        let end = min(location + max(range?.length ?? 0, 0), text.length)
        let start = max(0, location - maxBeforeCaret)
        let stop = min(text.length, end + maxAfterCaret)
        let before = text.substring(with: NSRange(location: start, length: location - start))
        let after = text.substring(with: NSRange(location: end, length: stop - end))
        return (nonBlank(before), nonBlank(after))
    }

    // MARK: - AX Helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
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

    /// Selected text in a web area, through its text-marker range.
    private static func webSelection(_ element: AXUIElement) -> String? {
        var markers: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markers) == .success,
              let markers
        else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, markers, &text
        ) == .success else { return nil }
        return text as? String
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(maxContextChars))
    }

    private static func nonBlank(_ s: String) -> String? {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}
