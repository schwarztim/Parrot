import AppKit
import Carbon
import KeyboardShortcuts

/// Manages global hotkey detection for push-to-talk recording.
///
/// Uses a hybrid approach for maximum compatibility:
/// - **Key combos** (e.g., Cmd+Shift+Space): Uses `KeyboardShortcuts` library
///   which wraps Carbon `RegisterEventHotKey` — requires **no permissions**.
/// - **Modifier-only keys** (e.g., Right Option): Uses both global and local
///   `NSEvent` monitors for `.flagsChanged` — global needs **Accessibility**
///   permission; local works without any permissions.
/// - **Mouse buttons**: Uses both global and local `NSEvent` monitors for
///   `.otherMouseDown/.otherMouseUp` — global needs **Accessibility** permission.
final class HotkeyManager {

    // MARK: - Types

    struct GlobalHotkeyBinding: Codable, Equatable {
        var keyCode: Int
        var modifierFlags: UInt64
        var isModifierOnly: Bool
        var isMouseButton: Bool = false
        var mouseButton: Int = 0

        static let rightOption = GlobalHotkeyBinding(
            keyCode: kVK_RightOption,
            modifierFlags: 0,
            isModifierOnly: true
        )
    }

    // MARK: - Callbacks

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    // MARK: - Configuration

    var binding: GlobalHotkeyBinding = .rightOption {
        didSet {
            guard binding != oldValue else { return }
            reinstallListeners()
        }
    }

    // MARK: - Private State

    private var isKeyDown = false
    private var shortcutTask: Task<Void, Never>?
    private var lastModifierKeyCode: UInt16?
    private var isRunning = false

    // Global monitors (fire when OTHER apps are focused — need Accessibility)
    private var globalFlagsMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?

    // Local monitors (fire when PARROT is focused — no permissions needed)
    private var localFlagsMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var localMouseUpMonitor: Any?

    // MARK: - Lifecycle

    deinit {
        stop()
    }

    /// Starts listening for the configured hotkey.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        installListeners()
    }

    /// Stops listening and cleans up all monitors.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeAllListeners()
    }

    // MARK: - Private

    private func reinstallListeners() {
        guard isRunning else { return }
        removeAllListeners()
        installListeners()
    }

    private func installListeners() {
        if binding.isMouseButton {
            installMouseListeners()
        } else if binding.isModifierOnly {
            installModifierListener()
        } else {
            installKeyComboListener()
        }
    }

    private func removeAllListeners() {
        // Remove global NSEvent monitors
        for monitor in [globalFlagsMonitor, globalMouseDownMonitor, globalMouseUpMonitor] {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
        globalFlagsMonitor = nil
        globalMouseDownMonitor = nil
        globalMouseUpMonitor = nil

        // Remove local NSEvent monitors
        for monitor in [localFlagsMonitor, localMouseDownMonitor, localMouseUpMonitor] {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
        localFlagsMonitor = nil
        localMouseDownMonitor = nil
        localMouseUpMonitor = nil

        // Cancel KeyboardShortcuts async stream
        shortcutTask?.cancel()
        shortcutTask = nil

        // Unregister the Carbon hotkey
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)

        isKeyDown = false
        lastModifierKeyCode = nil
    }

    // MARK: - Key Combo (via KeyboardShortcuts — no permissions needed)

    private func installKeyComboListener() {
        let carbonMods = nsModifiersToCarbonModifiers(UInt64(binding.modifierFlags))
        let shortcut = KeyboardShortcuts.Shortcut(
            carbonKeyCode: binding.keyCode,
            carbonModifiers: carbonMods
        )
        KeyboardShortcuts.setShortcut(shortcut, for: .toggleRecording)

        shortcutTask = Task { @MainActor [weak self] in
            for await event in KeyboardShortcuts.events(for: .toggleRecording) {
                guard let self else { return }
                switch event {
                case .keyDown:
                    if !self.isKeyDown {
                        self.isKeyDown = true
                        diagLog("[Parrot:HotkeyManager] KeyCombo DOWN")
                        self.onKeyDown?()
                    }
                case .keyUp:
                    if self.isKeyDown {
                        self.isKeyDown = false
                        diagLog("[Parrot:HotkeyManager] KeyCombo UP")
                        self.onKeyUp?()
                    }
                }
            }
        }

        diagLog("[Parrot:HotkeyManager] Key combo listener installed (keyCode=\(binding.keyCode), mods=\(binding.modifierFlags))")
    }

    /// Converts NSEvent modifier flags (stored as CGEventFlags raw value in the binding)
    /// to Carbon modifier flags used by RegisterEventHotKey.
    private func nsModifiersToCarbonModifiers(_ flags: UInt64) -> Int {
        var carbon = 0
        let cgFlags = CGEventFlags(rawValue: flags)
        if cgFlags.contains(.maskCommand) { carbon |= cmdKey }
        if cgFlags.contains(.maskShift) { carbon |= shiftKey }
        if cgFlags.contains(.maskAlternate) { carbon |= optionKey }
        if cgFlags.contains(.maskControl) { carbon |= controlKey }
        return carbon
    }

    // MARK: - Modifier-Only (via NSEvent monitors)

    private func installModifierListener() {
        // Global monitor: fires when OTHER apps are focused (needs Accessibility).
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor: fires when PARROT window is focused (no permissions needed).
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        let hasGlobal = globalFlagsMonitor != nil
        let hasLocal = localFlagsMonitor != nil
        diagLog("[Parrot:HotkeyManager] Modifier listeners installed (global=\(hasGlobal), local=\(hasLocal), keyCode=\(binding.keyCode))")

        if !hasGlobal {
            diagLog("[Parrot:HotkeyManager] WARNING: Global monitor FAILED to install — Accessibility permission likely not granted. Hotkey will only work when Parrot window is focused.")
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifierKeyCodes: Set<UInt16> = [
            0x3A, 0x3D, // Left/Right Option
            0x37, 0x36, // Left/Right Command
            0x38, 0x3C, // Left/Right Shift
            0x3B, 0x3E, // Left/Right Control
        ]

        guard modifierKeyCodes.contains(event.keyCode) else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.rawValue != 0 && Int(event.keyCode) == binding.keyCode {
            // Modifier pressed down
            if !isKeyDown {
                isKeyDown = true
                lastModifierKeyCode = event.keyCode
                diagLog("[Parrot:HotkeyManager] Modifier DOWN (keyCode=\(event.keyCode))")
                onKeyDown?()
            }
        } else if flags.rawValue == 0 && isKeyDown {
            // All modifiers released
            isKeyDown = false
            lastModifierKeyCode = nil
            diagLog("[Parrot:HotkeyManager] Modifier UP")
            onKeyUp?()
        }
    }

    // MARK: - Mouse Button (via NSEvent monitors)

    private func installMouseListeners() {
        // Global monitors (other apps focused)
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            self?.handleMouseDown(event)
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) {
            [weak self] event in
            self?.handleMouseUp(event)
        }

        // Local monitors (Parrot focused)
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) {
            [weak self] event in
            self?.handleMouseUp(event)
            return event
        }

        let hasGlobal = globalMouseDownMonitor != nil
        diagLog("[Parrot:HotkeyManager] Mouse listeners installed (global=\(hasGlobal), button=\(binding.mouseButton))")
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.buttonNumber == binding.mouseButton else { return }
        if !isKeyDown {
            isKeyDown = true
            diagLog("[Parrot:HotkeyManager] Mouse DOWN (button=\(event.buttonNumber))")
            onKeyDown?()
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard event.buttonNumber == binding.mouseButton else { return }
        if isKeyDown {
            isKeyDown = false
            diagLog("[Parrot:HotkeyManager] Mouse UP (button=\(event.buttonNumber))")
            onKeyUp?()
        }
    }
}

// MARK: - KeyboardShortcuts Name Extension

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
