import AppKit
import ApplicationServices

/// How a paste was sent. [OUT]
enum PasteMethod: String, Sendable {
    /// The frontmost app's Edit > Paste menu item, pressed through Accessibility.
    case menuAction
    /// A synthetic Cmd+V on the current keyboard layout.
    case keyboardShortcut
}

/// Sends text into the frontmost app. Every operation joins one queue, so
/// back-to-back results never interleave. [OUT]
///
/// Paste tries the app's Edit > Paste menu item first and falls back to
/// Cmd+V with the V key looked up on the current layout. The alert sound is
/// muted briefly around synthetic key presses. All of it needs
/// Accessibility; callers check trust first.
@MainActor
final class PasteEngine {

    let typer: KeystrokeTyper
    private let muter: AlertMuter
    private var tail: Task<Void, Never>?

    init(typer: KeystrokeTyper = KeystrokeTyper(), muter: AlertMuter) {
        self.typer = typer
        self.muter = muter
    }

    /// Runs `operation` after every earlier one has finished.
    func enqueue<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Pastes the clipboard into the frontmost app.
    func paste() async -> PasteMethod {
        await enqueue {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != ownPID {
                let pressed = await Task.detached(priority: .userInitiated) {
                    Self.pressPasteMenuItem(pid: pid)
                }.value
                if pressed {
                    diagLog("[Parrot:Output] Pasted text via menu action")
                    return .menuAction
                }
                diagLog("[Parrot:Output] Falling back to keyboard shortcut paste")
            }
            self.muter.muteBriefly()
            KeyEvents.press(KeyboardLayout.pasteKeyCode(), flags: .maskCommand)
            diagLog("[Parrot:Output] Pasted text via keyboard shortcut")
            return .keyboardShortcut
        }
    }

    /// Types `text` as key presses.
    func type(_ text: String) async {
        await enqueue {
            self.muter.muteBriefly(for: 0.6 + Double(text.count) * self.typer.interKeyDelay)
            await self.typer.type(text)
        }
    }

    /// Presses Return, after a short pause so the paste lands first.
    func pressReturn(after delay: TimeInterval = 0.15) async {
        await enqueue {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.muter.muteBriefly()
            KeyEvents.press(USQwerty.returnKey)
            diagLog("[Parrot:Output] Auto-submit: pressed Return")
        }
    }

    /// Polls the focused field until it shows the paste or `timeout` passes.
    /// Nothing waits on a field that cannot be read.
    func confirm(target: PasteTarget?, timeout: TimeInterval = 0.4, interval: TimeInterval = 0.06) async -> PasteConfirmation {
        guard let target, target.field.valueLength != nil else { return .unavailable }
        let deadline = Date().addingTimeInterval(timeout)
        var result = PasteConfirmation.unavailable
        repeat {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let now = await Task.detached(priority: .userInitiated) {
                CursorContextReader.focusedField().map { FocusedField(element: $0.element, field: $0.field) }
            }.value
            let same = now.map { CFEqual($0.element, target.element) } ?? false
            result = PasteConfirmation.evaluate(before: target.field, after: now?.field, sameElement: same)
            if result != .unconfirmed { break }
        } while Date() < deadline
        diagLog("[Parrot:Output] Paste confirmation: \(result)")
        return result
    }

    // MARK: - Menu Action

    /// Presses the enabled menu item bound to Cmd+V in `pid`'s menu bar.
    /// Matching the shortcut rather than the title works in every language.
    /// Blocking; runs off the main thread.
    nonisolated static func pressPasteMenuItem(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, CursorContextReader.messagingTimeout)
        guard let menuBar = CursorContextReader.element(app, kAXMenuBarAttribute) else { return false }

        // Edit is usually the fourth menu (after Apple, the app and File);
        // look near there first.
        let all = CursorContextReader.children(menuBar)
        let preferred = [3, 2, 4].filter { $0 < all.count }
        let rest = all.indices.filter { !preferred.contains($0) }
        for menuBarItem in (preferred + rest).map({ all[$0] }) {
            for menu in CursorContextReader.children(menuBarItem) {
                for item in CursorContextReader.children(menu) {
                    guard CursorContextReader.string(item, kAXMenuItemCmdCharAttribute)?.uppercased() == "V",
                          commandOnly(item)
                    else { continue }
                    guard bool(item, kAXEnabledAttribute) else { return false }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// Modifier value 0 means Command alone (not Paste and Match Style).
    private nonisolated static func commandOnly(_ item: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success,
              let number = value as? NSNumber
        else { return false }
        return number.intValue == 0
    }

    private nonisolated static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

/// A focused element handed back from a background read.
private struct FocusedField: @unchecked Sendable {
    let element: AXUIElement
    let field: FieldSnapshot
}
