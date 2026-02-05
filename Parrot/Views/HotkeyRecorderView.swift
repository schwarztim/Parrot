import SwiftUI
import Carbon
import CoreGraphics

struct HotkeyRecorderView: View {
    let label: String
    @Binding var binding: HotkeyBinding?

    @State private var isCapturing = false

    var body: some View {
        HStack {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                // Current Binding Display
                hotkeyDisplay

                // Record / Clear Buttons
                if isCapturing {
                    Button("Cancel") {
                        stopCapturing()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                } else {
                    Button("Record") {
                        startCapturing()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if binding != nil {
                        Button("Clear") {
                            binding = nil
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Hotkey Display

    private var hotkeyDisplay: some View {
        Group {
            if isCapturing {
                ZStack {
                    Text("Press shortcut...")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.orange.opacity(0.08))
                                )
                        )

                    // Invisible NSView that captures key/mouse events with proper keyCodes
                    KeyCaptureOverlay(
                        onCapture: { keyCode, modifiers, displayName in
                            binding = HotkeyBinding(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                displayName: displayName
                            )
                            stopCapturing()
                        },
                        onMouseCapture: { buttonNumber, displayName in
                            binding = HotkeyBinding(
                                keyCode: 0,
                                modifiers: [],
                                displayName: displayName,
                                mouseButton: buttonNumber
                            )
                            stopCapturing()
                        },
                        onCancel: {
                            stopCapturing()
                        }
                    )
                    .frame(width: 0, height: 0)
                }
            } else if let currentBinding = binding {
                Text(currentBinding.displayName)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                    )
            } else {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.controlBackgroundColor))
                    )
            }
        }
    }

    // MARK: - Capture

    private func startCapturing() {
        isCapturing = true
    }

    private func stopCapturing() {
        isCapturing = false
    }
}

// MARK: - Key Capture NSViewRepresentable

/// Invisible NSView that becomes first responder to capture key events with
/// proper Carbon keyCodes — something SwiftUI's `.onKeyPress()` cannot provide.
private struct KeyCaptureOverlay: NSViewRepresentable {
    let onCapture: (UInt16, NSEvent.ModifierFlags, String) -> Void
    let onMouseCapture: (Int, String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        view.onMouseCapture = onMouseCapture
        view.onCancel = onCancel
        // Defer first-responder request so the view is in the window hierarchy.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onMouseCapture = onMouseCapture
        nsView.onCancel = onCancel
    }
}

/// NSView subclass that handles `keyDown` and `flagsChanged` to capture
/// hotkey input with real Carbon virtual key codes.
///
/// Mouse button capture uses `NSEvent.addLocalMonitorForEvents` because
/// the view has a zero frame (overlaid invisibly) and macOS hit-testing
/// would never deliver mouse events to it.
final class KeyCaptureNSView: NSView {
    var onCapture: ((UInt16, NSEvent.ModifierFlags, String) -> Void)?
    var onMouseCapture: ((Int, String) -> Void)?
    var onCancel: (() -> Void)?

    /// Tracks whether a regular key was pressed while a modifier was held,
    /// so we can distinguish modifier-only bindings (e.g., Right Option alone).
    private var keyDownOccurred = false
    private var lastModifierKeyCode: UInt16?

    /// Local event monitor for mouse buttons (hit-test independent).
    private var mouseMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMouseMonitor()
        } else {
            removeMouseMonitor()
        }
    }

    deinit {
        removeMouseMonitor()
    }

    // MARK: - Mouse Button Capture

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self else { return event }
            let button = event.buttonNumber
            let displayName: String
            switch button {
            case 2: displayName = "Middle Mouse"
            case 3: displayName = "Mouse Button 4"
            case 4: displayName = "Mouse Button 5"
            default: displayName = "Mouse Button \(button)"
            }
            self.onMouseCapture?(button, displayName)
            return nil // consume the event
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Keyboard Capture

    override func keyDown(with event: NSEvent) {
        keyDownOccurred = true
        lastModifierKeyCode = nil

        // Escape cancels capture
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        // Build clean modifier flags (strip device-specific bits)
        var modifiers: NSEvent.ModifierFlags = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }

        let displayName = Self.buildDisplayName(
            keyCode: event.keyCode,
            modifiers: modifiers,
            characters: event.charactersIgnoringModifiers
        )
        onCapture?(event.keyCode, modifiers, displayName)
    }

    override func flagsChanged(with event: NSEvent) {
        let modifierKeyCodes: Set<UInt16> = [
            0x3A, 0x3D, // Left/Right Option
            0x37, 0x36, // Left/Right Command
            0x38, 0x3C, // Left/Right Shift
            0x3B, 0x3E, // Left/Right Control
        ]

        guard modifierKeyCodes.contains(event.keyCode) else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.rawValue != 0 {
            // Modifier pressed down — track it
            lastModifierKeyCode = event.keyCode
            keyDownOccurred = false
        } else if let modKey = lastModifierKeyCode, !keyDownOccurred {
            // All modifiers released without a regular key press — modifier-only binding
            let displayName = Self.describeModifierKey(modKey)
            onCapture?(modKey, [], displayName)
            lastModifierKeyCode = nil
        }
    }

    // MARK: - Display Name Helpers

    static func buildDisplayName(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }

        let keyName: String
        switch keyCode {
        case 49:  keyName = "Space"
        case 36:  keyName = "Return"
        case 48:  keyName = "Tab"
        case 51:  keyName = "Delete"
        case 117: keyName = "Forward Delete"
        case 123: keyName = "←"
        case 124: keyName = "→"
        case 125: keyName = "↓"
        case 126: keyName = "↑"
        case 115: keyName = "Home"
        case 119: keyName = "End"
        case 116: keyName = "Page Up"
        case 121: keyName = "Page Down"
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99:  keyName = "F3"
        case 118: keyName = "F4"
        case 96:  keyName = "F5"
        case 97:  keyName = "F6"
        case 98:  keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        default:
            keyName = characters?.uppercased() ?? "?"
        }

        parts.append(keyName)
        return parts.joined()
    }

    static func describeModifierKey(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0x3A: return "Left Option"
        case 0x3D: return "Right Option"
        case 0x37: return "Left Command"
        case 0x36: return "Right Command"
        case 0x38: return "Left Shift"
        case 0x3C: return "Right Shift"
        case 0x3B: return "Left Control"
        case 0x3E: return "Right Control"
        default:   return "Modifier"
        }
    }
}

// MARK: - Non-Optional Convenience Overload

extension HotkeyRecorderView {
    /// Convenience initializer for non-optional bindings (e.g., the toggle
    /// recording hotkey which always has a value).
    init(label: String, requiredBinding: Binding<HotkeyBinding>) {
        self.label = label
        self._binding = Binding(
            get: { requiredBinding.wrappedValue },
            set: { newValue in
                if let newValue {
                    requiredBinding.wrappedValue = newValue
                }
            }
        )
    }
}

#Preview {
    Form {
        HotkeyRecorderView(
            label: "Toggle Recording",
            requiredBinding: .constant(.defaultHotkey)
        )
        HotkeyRecorderView(
            label: "Cancel Recording",
            binding: .constant(nil)
        )
    }
    .formStyle(.grouped)
    .frame(width: 450, height: 200)
}
