import AppKit
import Carbon
import KeyboardShortcuts

/// Manages global hotkey detection for push-to-talk recording.
///
/// Uses a layered approach for maximum reliability:
/// - **Key combos** (e.g., Cmd+Shift+Space): Uses `KeyboardShortcuts` library
///   which wraps Carbon `RegisterEventHotKey` — requires **no permissions**.
/// - **Modifier-only keys** (e.g., Right Option): Dual-path — both `CGEventTap`
///   (`.listenOnly`, needs Input Monitoring on macOS 15+) and `NSEvent` global
///   monitor (needs Accessibility) run simultaneously. This ensures detection
///   even when one path is silently broken ("deaf tap" on macOS 15+).
///   `NSEvent` local monitor is always active (no permissions needed).
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
            modifierFlags: CGEventFlags.maskAlternate.rawValue,
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

    /// Optional callback if the CGEventTap is determined to be deaf.
    /// With the dual-path approach, NSEvent handles detection regardless.
    var onTapDeaf: (() -> Void)?

    // MARK: - Private State

    private var isKeyDown = false
    private var shortcutTask: Task<Void, Never>?
    private var isRunning = false

    // CGEventTap (primary for modifier-only — most reliable when permissions work)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installListeners()
    }

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
        // Remove CGEventTap
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil

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

    private func nsModifiersToCarbonModifiers(_ flags: UInt64) -> Int {
        var carbon = 0
        let cgFlags = CGEventFlags(rawValue: flags)
        if cgFlags.contains(.maskCommand) { carbon |= cmdKey }
        if cgFlags.contains(.maskShift) { carbon |= shiftKey }
        if cgFlags.contains(.maskAlternate) { carbon |= optionKey }
        if cgFlags.contains(.maskControl) { carbon |= controlKey }
        return carbon
    }

    // MARK: - Modifier-Only (CGEventTap + NSEvent in parallel)

    private func installModifierListener() {
        // CGEventTap: session-level, listen-only tap into HID stream.
        // Most reliable when Input Monitoring is properly granted.
        // On macOS 15+, the tap can be "deaf" (created successfully but
        // silently dropping all physical events). NSEvent global monitor
        // runs in parallel as a guaranteed detection path.
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

                // Re-enable if system disabled our tap (e.g., callback too slow).
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = mgr.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    diagLog("[Parrot:HotkeyManager] CGEventTap re-enabled after system disable")
                    return Unmanaged.passUnretained(event)
                }

                guard type == .flagsChanged else {
                    return Unmanaged.passUnretained(event)
                }

                mgr.handleCGFlagsChanged(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let tap {
            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            diagLog("[Parrot:HotkeyManager] CGEventTap installed (keyCode=\(binding.keyCode))")
        } else {
            diagLog("[Parrot:HotkeyManager] CGEventTap FAILED to create")
        }

        // ALWAYS install NSEvent global monitor alongside CGEventTap.
        // On macOS 15+, CGEventTap can be created successfully but silently
        // drop all physical events ("deaf tap") due to Input Monitoring TCC
        // issues. NSEvent global monitor uses Accessibility TCC (separate,
        // more reliable permission). The isKeyDown state machine prevents
        // double-firing when both paths deliver the same event.
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
        }
        if globalFlagsMonitor == nil {
            diagLog("[Parrot:HotkeyManager] WARNING: NSEvent global monitor FAILED — no Accessibility?")
        } else {
            diagLog("[Parrot:HotkeyManager] NSEvent global monitor installed (parallel listener)")
        }

        // Always install local monitor — works when Parrot is focused, no permissions.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        let hasTap = eventTap != nil
        let hasGlobal = globalFlagsMonitor != nil
        let hasLocal = localFlagsMonitor != nil
        diagLog("[Parrot:HotkeyManager] Modifier listeners: cgEventTap=\(hasTap), globalNSEvent=\(hasGlobal), localNSEvent=\(hasLocal), keyCode=\(binding.keyCode)")
    }

    // MARK: - Modifier Target Flags

    /// The CGEventFlags bit for the configured modifier key.
    private var targetCGFlag: CGEventFlags {
        switch binding.keyCode {
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        case 0x38, 0x3C: return .maskShift
        case 0x3B, 0x3E: return .maskControl
        default: return []
        }
    }

    /// The NSEvent.ModifierFlags bit for the configured modifier key.
    private var targetNSFlag: NSEvent.ModifierFlags {
        switch binding.keyCode {
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        default: return []
        }
    }

    // MARK: - Modifier Event Handlers

    /// Handles flagsChanged from CGEventTap (primary path).
    private func handleCGFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Log ALL modifier events for diagnostics — helps identify wrong
        // keyCode mappings, remapping software, or non-delivery.
        diagLog("[Parrot:HotkeyManager] CGEventTap event: keyCode=\(keyCode), flags=0x\(String(flags.rawValue, radix: 16)), binding=\(binding.keyCode)")

        let modifierKeyCodes: Set<Int64> = [
            0x3A, 0x3D, // Left/Right Option
            0x37, 0x36, // Left/Right Command
            0x38, 0x3C, // Left/Right Shift
            0x3B, 0x3E, // Left/Right Control
        ]
        guard modifierKeyCodes.contains(keyCode) else { return }

        let target = targetCGFlag

        if flags.contains(target) && keyCode == Int64(binding.keyCode) {
            if !isKeyDown {
                isKeyDown = true
                diagLog("[Parrot:HotkeyManager] Modifier DOWN via CGEventTap (keyCode=\(keyCode))")
                onKeyDown?()
            }
        } else if !flags.contains(target) && isKeyDown {
            isKeyDown = false
            diagLog("[Parrot:HotkeyManager] Modifier UP via CGEventTap")
            onKeyUp?()
        }
    }

    /// Handles flagsChanged from NSEvent monitors (global + local).
    private func handleFlagsChanged(_ event: NSEvent) {
        // Log ALL modifier events for diagnostics.
        diagLog("[Parrot:HotkeyManager] NSEvent flagsChanged: keyCode=\(event.keyCode), flags=0x\(String(event.modifierFlags.rawValue, radix: 16)), binding=\(binding.keyCode)")

        let modifierKeyCodes: Set<UInt16> = [
            0x3A, 0x3D, // Left/Right Option
            0x37, 0x36, // Left/Right Command
            0x38, 0x3C, // Left/Right Shift
            0x3B, 0x3E, // Left/Right Control
        ]
        guard modifierKeyCodes.contains(event.keyCode) else { return }

        let flags = event.modifierFlags
        let target = targetNSFlag

        if flags.contains(target) && Int(event.keyCode) == binding.keyCode {
            if !isKeyDown {
                isKeyDown = true
                diagLog("[Parrot:HotkeyManager] Modifier DOWN via NSEvent (keyCode=\(event.keyCode))")
                onKeyDown?()
            }
        } else if !flags.contains(target) && isKeyDown {
            isKeyDown = false
            diagLog("[Parrot:HotkeyManager] Modifier UP via NSEvent")
            onKeyUp?()
        }
    }

    // MARK: - Mouse Button (via NSEvent monitors)

    private func installMouseListeners() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            self?.handleMouseDown(event)
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) {
            [weak self] event in
            self?.handleMouseUp(event)
        }

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
