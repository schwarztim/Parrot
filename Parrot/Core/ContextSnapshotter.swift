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

    /// Maximum characters of surrounding field text to capture.
    private static let maxContextChars = 1200
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

        let selected = string(focused, kAXSelectedTextAttribute)
        context.selectedText = trimmed(selected)

        if let value = string(focused, kAXValueAttribute) {
            context.isEmptyField = value.isEmpty
            // Keep only the tail (text nearest the cursor) within the cap.
            if value.count > maxContextChars {
                context.textBeforeCursor = String(value.suffix(maxContextChars))
            } else {
                context.textBeforeCursor = trimmed(value)
            }
        }

        return context
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

    private static func trimmed(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(maxContextChars))
    }
}
