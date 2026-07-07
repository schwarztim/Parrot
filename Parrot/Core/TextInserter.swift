import AppKit
import CoreGraphics

/// Inserts text into the frontmost application by simulating Cmd+V paste.
///
/// The text is placed on the general pasteboard and left there after pasting,
/// so the dictation survives even if the target app rejects the paste.
final class TextInserter {

    // MARK: - Public API

    /// Copies the given text to the pasteboard and pastes it into the focused
    /// text field of the frontmost app. The text remains on the pasteboard.
    ///
    /// Thread-safe. Can be called from any actor/task context.
    /// - Parameter text: The text to insert.
    static func insertText(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCmdV()
    }

    // MARK: - CGEvent Simulation

    /// Posts Cmd+V key events (key down + key up) to the HID event tap.
    private static func postCmdV() {
        let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
