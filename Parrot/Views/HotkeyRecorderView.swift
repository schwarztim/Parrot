import SwiftUI
import Carbon
import CoreGraphics

/// One shortcut row: label and description, key caps, reset to default and
/// remove. [TRG]
///
/// Clicking the key caps (or "Record shortcut...") captures the next key
/// combination, lone modifier (left and right apart, Fn, Caps Lock) or
/// mouse button 2 and up. Escape cancels capture. A capture that `conflict`
/// reports as taken is refused with "Already in use". Global shortcuts pause
/// while capturing so a key that is bound today can be recorded again.
struct HotkeyRecorderView: View {
    let label: String
    let summary: String?
    @Binding var shortcut: Shortcut?
    let defaultShortcut: Shortcut?
    let allowsKeys: Bool
    let allowsMouse: Bool
    /// Returns the name of whatever already uses the candidate, or nil.
    let conflict: (Shortcut) -> String?

    @State private var isCapturing = false
    @State private var heldModifiers = ""
    @State private var refusal: String?

    init(
        label: String,
        summary: String? = nil,
        shortcut: Binding<Shortcut?>,
        defaultShortcut: Shortcut? = nil,
        allowsKeys: Bool = true,
        allowsMouse: Bool = true,
        conflict: @escaping (Shortcut) -> String? = { _ in nil }
    ) {
        self.label = label
        self.summary = summary
        self._shortcut = shortcut
        self.defaultShortcut = defaultShortcut
        self.allowsKeys = allowsKeys
        self.allowsMouse = allowsMouse
        self.conflict = conflict
    }

    private var current: Shortcut? {
        guard let shortcut, !shortcut.isEmpty else { return nil }
        return shortcut
    }

    private var canReset: Bool {
        guard let defaultShortcut, !defaultShortcut.isEmpty else { return false }
        return current != defaultShortcut
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let refusal {
                    Text(refusal)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            recorderField

            if !isCapturing {
                if canReset {
                    Button {
                        if let defaultShortcut { accept(defaultShortcut) }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to default")
                }
                if current != nil {
                    Button {
                        refusal = nil
                        shortcut = Shortcut.none
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
        }
        .onDisappear { stopCapturing() }
    }

    // MARK: - Recorder Field

    @ViewBuilder
    private var recorderField: some View {
        if isCapturing {
            ZStack {
                Text(heldModifiers.isEmpty ? capturePrompt : heldModifiers)
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
                    allowsKeys: allowsKeys,
                    allowsMouse: allowsMouse,
                    onCapture: { accept($0) },
                    onModifiersChanged: { heldModifiers = $0 },
                    onCancel: { stopCapturing() }
                )
                .frame(width: 0, height: 0)
            }

            Button("Cancel") {
                stopCapturing()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        } else {
            Button {
                startCapturing()
            } label: {
                if let current {
                    ShortcutKeycaps(shortcut: current)
                } else {
                    Text("Record shortcut...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.controlBackgroundColor))
                        )
                }
            }
            .buttonStyle(.plain)
            .help("Click to record a new shortcut")
            .contextMenu {
                if let current, current.isModifierOnly {
                    Toggle("Double-tap to trigger", isOn: Binding(
                        get: { current.doubleTap },
                        set: { isOn in
                            var updated = current
                            updated.doubleTap = isOn
                            shortcut = updated
                        }
                    ))
                }
            }
        }
    }

    private var capturePrompt: String {
        allowsKeys ? "Press any key to set your shortcut..." : "Click a mouse button..."
    }

    // MARK: - Capture

    private func startCapturing() {
        refusal = nil
        heldModifiers = ""
        isCapturing = true
        NotificationCenter.default.post(name: .parrotShortcutCaptureDidBegin, object: nil)
    }

    private func stopCapturing() {
        guard isCapturing else { return }
        isCapturing = false
        heldModifiers = ""
        NotificationCenter.default.post(name: .parrotShortcutCaptureDidEnd, object: nil)
    }

    private func accept(_ candidate: Shortcut) {
        stopCapturing()
        if let other = conflict(candidate) {
            refusal = "Already in use by \(other)"
            return
        }
        refusal = nil
        shortcut = candidate
    }
}

// MARK: - Key Caps

/// A shortcut drawn as key caps, for example ⌥ Space or Right ⌘. [TRG]
struct ShortcutKeycaps: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                    )
            }
            if shortcut.doubleTap {
                Text("×2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayName)
    }
}

// MARK: - Key Capture NSViewRepresentable

/// Invisible NSView that becomes first responder to capture key events with
/// proper Carbon keyCodes, which SwiftUI's `.onKeyPress()` cannot provide.
private struct KeyCaptureOverlay: NSViewRepresentable {
    let allowsKeys: Bool
    let allowsMouse: Bool
    let onCapture: (Shortcut) -> Void
    let onModifiersChanged: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        configure(view)
        // Defer first-responder request so the view is in the window hierarchy.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: KeyCaptureNSView) {
        view.allowsKeys = allowsKeys
        view.allowsMouse = allowsMouse
        view.onShortcut = onCapture
        view.onModifiersChanged = onModifiersChanged
        view.onCancel = onCancel
    }
}

/// NSView subclass that handles `keyDown` and `flagsChanged` to capture
/// hotkey input with real Carbon virtual key codes.
///
/// Mouse button capture uses `NSEvent.addLocalMonitorForEvents` because
/// the view has a zero frame (overlaid invisibly) and macOS hit-testing
/// would never deliver mouse events to it.
final class KeyCaptureNSView: NSView {
    var allowsKeys = true
    var allowsMouse = true
    /// The captured shortcut.
    var onShortcut: ((Shortcut) -> Void)?
    /// The modifiers held right now, as symbols, for live feedback.
    var onModifiersChanged: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// Older callbacks, still fired alongside `onShortcut`.
    var onCapture: ((UInt16, NSEvent.ModifierFlags, String) -> Void)?
    var onMouseCapture: ((Int, String) -> Void)?

    /// Tracks whether a regular key was pressed while a modifier was held,
    /// so we can distinguish modifier-only bindings (e.g., Right Option alone).
    private var keyDownOccurred = false
    private var lastModifierKeyCode: UInt16?

    /// Local event monitor for mouse buttons (hit-test independent).
    private var mouseMonitor: Any?

    private static let heldFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]

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
            guard let self, self.allowsMouse else { return event }
            let button = event.buttonNumber
            let shortcut = Shortcut.mouse(button)
            self.onMouseCapture?(button, shortcut.displayName)
            self.onShortcut?(shortcut)
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
        guard allowsKeys else { return }

        // Build clean modifier flags (strip device-specific bits)
        var modifiers: NSEvent.ModifierFlags = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }

        let shortcut = Shortcut(keyCode: Int(event.keyCode), modifiers: modifiers)
        onCapture?(event.keyCode, modifiers, shortcut.displayName)
        onShortcut?(shortcut)
    }

    override func flagsChanged(with event: NSEvent) {
        guard allowsKeys, Shortcut.loneModifierKeyCodes.contains(Int(event.keyCode)) else { return }

        // Caps Lock reports only its state flipping, so take it at once.
        if Int(event.keyCode) == Shortcut.capsLockKeyCode {
            captureLoneModifier(event.keyCode)
            return
        }

        let flags = event.modifierFlags.intersection(Self.heldFlags)
        onModifiersChanged?(Self.symbols(for: flags))

        if !flags.isEmpty {
            // Modifier pressed down: track it
            lastModifierKeyCode = event.keyCode
            keyDownOccurred = false
        } else if let modKey = lastModifierKeyCode, !keyDownOccurred {
            // All modifiers released without a regular key press: modifier-only binding
            captureLoneModifier(modKey)
        }
    }

    private func captureLoneModifier(_ keyCode: UInt16) {
        let shortcut = Shortcut.key(Int(keyCode))
        lastModifierKeyCode = nil
        onCapture?(keyCode, [], shortcut.displayName)
        onShortcut?(shortcut)
    }

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var parts = ""
        if flags.contains(.function) { parts += "fn " }
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts
    }

    // MARK: - Display Name Helpers

    static func buildDisplayName(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> String {
        Shortcut(keyCode: Int(keyCode), modifiers: modifiers).displayName
    }

    static func describeModifierKey(_ keyCode: UInt16) -> String {
        Shortcut.loneModifierName(Int(keyCode))
    }
}

// MARK: - HotkeyBinding Convenience

extension HotkeyRecorderView {
    /// A recorder over an optional `HotkeyBinding`.
    init(label: String, binding: Binding<HotkeyBinding?>) {
        self.init(label: label, shortcut: Binding(
            get: { binding.wrappedValue.flatMap { Shortcut(legacy: $0) } },
            set: { binding.wrappedValue = $0?.legacyBinding }
        ))
    }

    /// Convenience initializer for non-optional bindings (e.g., the toggle
    /// recording hotkey which always has a value). Remove is ignored.
    init(label: String, requiredBinding: Binding<HotkeyBinding>) {
        self.init(label: label, shortcut: Binding(
            get: { Shortcut(legacy: requiredBinding.wrappedValue) },
            set: { newValue in
                if let binding = newValue?.legacyBinding {
                    requiredBinding.wrappedValue = binding
                }
            }
        ))
    }
}

#Preview {
    Form {
        HotkeyRecorderView(
            label: "Toggle Recording",
            summary: "Starts and stops recordings",
            shortcut: .constant(.key(0x31, .option)),
            defaultShortcut: .key(0x31, .option)
        )
        HotkeyRecorderView(
            label: "Push to Talk",
            summary: "Hold to record, release when done",
            shortcut: .constant(.key(0x36)),
            defaultShortcut: .key(0x3D)
        )
        HotkeyRecorderView(
            label: "Cancel Recording",
            binding: .constant(nil)
        )
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 260)
}
