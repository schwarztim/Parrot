import AppKit
import CoreGraphics

/// Inserts text into the frontmost application by simulating Cmd+V paste.
///
/// The current pasteboard contents are saved, the transcription text is placed
/// on the pasteboard with a transient marker (so clipboard managers ignore it),
/// Cmd+V is simulated, and the original pasteboard is restored after a short delay.
final class TextInserter {

    // MARK: - Public API

    /// Inserts the given text into the focused text field of the frontmost app.
    ///
    /// Thread-safe. Can be called from any actor/task context.
    /// - Parameter text: The text to insert.
    static func insertText(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // 1. Save current pasteboard contents (all types).
        let savedItems = savePasteboard(pasteboard)

        // 2. Set transcription text with transient marker.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Mark as transient so clipboard managers (e.g., Paste, Maccy) ignore it.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        // 3. Simulate Cmd+V.
        postCmdV()

        // 4. Restore original pasteboard after a brief delay to ensure the
        //    paste event has been processed by the target app.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        restorePasteboard(pasteboard, items: savedItems)
    }

    // MARK: - Pasteboard Save / Restore

    /// Captures all items and their associated types from the pasteboard.
    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }

        return items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    /// Restores previously saved items to the pasteboard.
    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        items: [[NSPasteboard.PasteboardType: Data]]
    ) {
        pasteboard.clearContents()

        guard !items.isEmpty else { return }

        let pasteboardItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(pasteboardItems)
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
