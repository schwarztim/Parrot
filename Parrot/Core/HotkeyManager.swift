import AppKit
import Carbon
import KeyboardShortcuts

/// Detects every global shortcut binding and reports presses by id.
///
/// Uses a layered approach for maximum reliability:
/// - **Key combos** (e.g., Option+Space): `KeyboardShortcuts` library, which
///   wraps Carbon `RegisterEventHotKey`; requires **no permissions**. One
///   library name per registration id.
/// - **Lone modifier keys** (e.g., Right Option, Fn): dual path, both
///   `CGEventTap` (`.listenOnly`, needs Input Monitoring on macOS 15+) and
///   `NSEvent` global monitor (needs Accessibility) run simultaneously. This
///   ensures detection even when one path is silently broken ("deaf tap" on
///   macOS 15+). `NSEvent` local monitor is always active (no permissions).
///   Key down events on the same paths report a key combination typed while
///   a lone modifier is held (`.interrupted`).
/// - **Fn/Globe and Caps Lock**: `HIDKeyMonitor` when it can open the
///   keyboards, else the flagsChanged path above.
/// - **Mouse buttons**: both global and local `NSEvent` monitors for
///   `.otherMouseDown/.otherMouseUp`; global needs **Accessibility**.
///
/// Listeners are installed once by `start()`. `setBindings(_:)` only
/// re-registers the key combos that changed, so a key held across an
/// update keeps its state.
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

        var isKeyCombo: Bool { !isModifierOnly && !isMouseButton }
    }

    enum Event: Equatable, Sendable {
        case down
        case up
        /// Another key went down while this lone modifier was held.
        case interrupted
    }

    // MARK: - Callbacks

    /// Every registration's presses, by registration id. Called on the main thread.
    var onEvent: ((String, Event) -> Void)?

    /// The primary registration's presses only (kept for older callers).
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    // MARK: - Configuration

    /// Registration id of the primary binding (push to talk).
    static let primaryID = "pushToTalk"

    /// The primary binding. Setting it replaces only that registration.
    var binding: GlobalHotkeyBinding {
        get { registrations[Self.primaryID] ?? .rightOption }
        set {
            var updated = registrations
            updated[Self.primaryID] = newValue
            setBindings(updated)
        }
    }

    /// Every binding by registration id.
    private(set) var registrations: [String: GlobalHotkeyBinding] = [:]

    /// While true, nothing is reported and no key combo is registered, so a
    /// shortcut recorder can capture keys that are bound today.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue, isRunning else { return }
            if isPaused {
                release(downIDs)
                for id in Array(comboTasks.keys) { removeCombo(id) }
            } else {
                updateCombos(from: [:], to: registrations)
            }
        }
    }

    /// Optional callback if the CGEventTap is determined to be deaf.
    /// With the dual-path approach, NSEvent handles detection regardless.
    var onTapDeaf: (() -> Void)?

    // MARK: - Private State

    private var isRunning = false
    private var downIDs: Set<String> = []
    private var comboTasks: [String: Task<Void, Never>] = [:]
    private let hid = HIDKeyMonitor()
    /// Last Caps Lock state seen through flagsChanged (fallback path).
    private var lastCapsLockOn: Bool?

    // CGEventTap (primary for modifier-only, most reliable when permissions work)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Global monitors (fire when OTHER apps are focused; need Accessibility)
    private var globalMonitors: [Any] = []
    // Local monitors (fire when PARROT is focused; no permissions needed)
    private var localMonitors: [Any] = []

    // MARK: - Lifecycle

    deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Clear the single-binding registration older builds left behind.
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)
        installEventListeners()
        if !isPaused { updateCombos(from: [:], to: registrations) }
        updateHID()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for id in Array(comboTasks.keys) { removeCombo(id) }
        removeEventListeners()
        hid.stop()
        downIDs.removeAll()
    }

    /// Replaces every registration. Unchanged ids keep their listener and
    /// their pressed state.
    func setBindings(_ bindings: [String: GlobalHotkeyBinding]) {
        let old = registrations
        registrations = bindings
        release(downIDs.filter { old[$0] != bindings[$0] })
        guard isRunning else { return }
        if !isPaused { updateCombos(from: old, to: bindings) }
        updateHID()
    }

    // MARK: - Reporting

    private func keyDown(_ id: String) {
        guard !isPaused, !downIDs.contains(id) else { return }
        downIDs.insert(id)
        diagLog("[Parrot:HotkeyManager] DOWN \(id)")
        if id == Self.primaryID { onKeyDown?() }
        onEvent?(id, .down)
    }

    private func keyUp(_ id: String) {
        guard downIDs.remove(id) != nil else { return }
        diagLog("[Parrot:HotkeyManager] UP \(id)")
        if id == Self.primaryID { onKeyUp?() }
        onEvent?(id, .up)
    }

    /// Reports a release for keys whose registration goes away while held,
    /// so a listener never waits for a release that cannot arrive.
    private func release(_ ids: Set<String>) {
        for id in ids.sorted() { keyUp(id) }
    }

    // MARK: - Key Combos (via KeyboardShortcuts; no permissions needed)

    /// Removes changed combos before adding, so a shortcut moving from one
    /// id to another is never unregistered after its new owner registered it.
    private func updateCombos(from old: [String: GlobalHotkeyBinding], to new: [String: GlobalHotkeyBinding]) {
        let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] || comboTasks[$0] == nil }
        for id in changed where comboTasks[id] != nil { removeCombo(id) }
        for id in changed.sorted() {
            if let binding = new[id], binding.isKeyCombo { addCombo(id, binding) }
        }
    }

    private func addCombo(_ id: String, _ binding: GlobalHotkeyBinding) {
        let name = KeyboardShortcuts.Name("parrot.\(id)")
        let flags = NSEvent.ModifierFlags(rawValue: UInt(binding.modifierFlags))
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(
                carbonKeyCode: binding.keyCode,
                carbonModifiers: SuperwhisperShortcut.carbonModifiers(flags)
            ),
            for: name
        )
        comboTasks[id] = Task { @MainActor [weak self] in
            for await event in KeyboardShortcuts.events(for: name) {
                guard let self else { return }
                switch event {
                case .keyDown: self.keyDown(id)
                case .keyUp: self.keyUp(id)
                }
            }
        }
        diagLog("[Parrot:HotkeyManager] Key combo registered \(id) (keyCode=\(binding.keyCode), mods=\(binding.modifierFlags))")
    }

    private func removeCombo(_ id: String) {
        comboTasks.removeValue(forKey: id)?.cancel()
        KeyboardShortcuts.setShortcut(nil, for: KeyboardShortcuts.Name("parrot.\(id)"))
        downIDs.remove(id)
    }

    // MARK: - Event Listeners (CGEventTap + NSEvent in parallel)

    private func installEventListeners() {
        // CGEventTap: session-level, listen-only tap into the HID stream.
        // On macOS 15+, the tap can be "deaf" (created successfully but
        // silently dropping all physical events). NSEvent global monitors
        // run in parallel as a guaranteed detection path; downIDs keeps the
        // two paths from double-firing.
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

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

                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .flagsChanged {
                    mgr.handleFlagsChanged(keyCode: keyCode, flags: event.flags.rawValue)
                } else if type == .keyDown {
                    mgr.handleKeyDown(keyCode: keyCode)
                }
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
        } else {
            diagLog("[Parrot:HotkeyManager] CGEventTap FAILED to create")
        }

        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(keyCode: Int(event.keyCode), flags: UInt64(event.modifierFlags.rawValue))
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(keyCode: Int(event.keyCode))
        }
        let mouseDown = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            self?.handleMouse(button: event.buttonNumber, isDown: true)
        }
        let mouseUp = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            self?.handleMouse(button: event.buttonNumber, isDown: false)
        }
        globalMonitors = [flags, keys, mouseDown, mouseUp].compactMap { $0 }
        if flags == nil {
            diagLog("[Parrot:HotkeyManager] WARNING: NSEvent global monitor FAILED; no Accessibility?")
        }

        localMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(keyCode: Int(event.keyCode), flags: UInt64(event.modifierFlags.rawValue))
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(keyCode: Int(event.keyCode))
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                self?.handleMouse(button: event.buttonNumber, isDown: true)
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                self?.handleMouse(button: event.buttonNumber, isDown: false)
                return event
            },
        ].compactMap { $0 }

        diagLog("[Parrot:HotkeyManager] Listeners: cgEventTap=\(eventTap != nil), globalNSEvent=\(flags != nil), localNSEvent=\(!localMonitors.isEmpty)")
    }

    private func removeEventListeners() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        for monitor in globalMonitors + localMonitors { NSEvent.removeMonitor(monitor) }
        globalMonitors = []
        localMonitors = []
    }

    // MARK: - Lone Modifier Keys

    /// Generic flag and device-specific (left or right) flag per key code.
    private static let modifierMasks: [Int: (generic: UInt64, device: UInt64)] = [
        0x37: (CGEventFlags.maskCommand.rawValue, 0x08),   // Left Command
        0x36: (CGEventFlags.maskCommand.rawValue, 0x10),   // Right Command
        0x38: (CGEventFlags.maskShift.rawValue, 0x02),     // Left Shift
        0x3C: (CGEventFlags.maskShift.rawValue, 0x04),     // Right Shift
        0x3A: (CGEventFlags.maskAlternate.rawValue, 0x20), // Left Option
        0x3D: (CGEventFlags.maskAlternate.rawValue, 0x40), // Right Option
        0x3B: (CGEventFlags.maskControl.rawValue, 0x01),   // Left Control
        0x3E: (CGEventFlags.maskControl.rawValue, 0x2000), // Right Control
        0x3F: (CGEventFlags.maskSecondaryFn.rawValue, 0),  // Fn
    ]

    /// Device bits of both sides of a modifier family.
    private static func familyDeviceMask(_ generic: UInt64) -> UInt64 {
        modifierMasks.values.filter { $0.generic == generic }.reduce(0) { $0 | $1.device }
    }

    /// Whether the key is held according to the flags. Uses the left or
    /// right device bit when the keyboard reports one, else the generic flag.
    static func isPressed(keyCode: Int, flags: UInt64) -> Bool {
        guard let masks = modifierMasks[keyCode] else { return false }
        if masks.device != 0, flags & familyDeviceMask(masks.generic) != 0 {
            return flags & masks.device != 0
        }
        return flags & masks.generic != 0
    }

    /// Handles flagsChanged from the tap and the NSEvent monitors. NSEvent
    /// modifier flags use the same bits as CGEventFlags.
    private func handleFlagsChanged(keyCode: Int, flags: UInt64) {
        guard !isPaused else { return }
        let hidOwns: Set<Int> = hid.isOpen ? [Shortcut.functionKeyCode, Shortcut.capsLockKeyCode] : []

        // A lost release from the HID stream: Fn no longer in the flags.
        if hid.isOpen, flags & CGEventFlags.maskSecondaryFn.rawValue == 0 {
            hid.noteReleased(Shortcut.functionKeyCode)
        }

        if keyCode == Shortcut.capsLockKeyCode, !hidOwns.contains(keyCode) {
            // flagsChanged only reports the Caps Lock state flipping, so
            // each flip is one whole press.
            let isOn = flags & CGEventFlags.maskAlphaShift.rawValue != 0
            defer { lastCapsLockOn = isOn }
            guard lastCapsLockOn != isOn else { return }
            for (id, binding) in registrations where binding.isModifierOnly && binding.keyCode == keyCode {
                keyDown(id)
                keyUp(id)
            }
            return
        }

        for (id, binding) in registrations where binding.isModifierOnly && !binding.isMouseButton {
            guard !hidOwns.contains(binding.keyCode), Self.modifierMasks[binding.keyCode] != nil else { continue }
            let pressed = Self.isPressed(keyCode: binding.keyCode, flags: flags)
            if pressed, keyCode == binding.keyCode {
                keyDown(id)
            } else if !pressed {
                keyUp(id)
            }
        }
    }

    /// A non-modifier key went down: every held lone modifier was part of a
    /// key combination.
    private func handleKeyDown(keyCode: Int) {
        guard !isPaused, !Shortcut.loneModifierKeyCodes.contains(keyCode) else { return }
        for id in downIDs where registrations[id]?.isModifierOnly == true {
            onEvent?(id, .interrupted)
        }
    }

    // MARK: - Fn and Caps Lock (HID)

    private func updateHID() {
        let needed = registrations.values.contains {
            $0.isModifierOnly && ($0.keyCode == Shortcut.functionKeyCode || $0.keyCode == Shortcut.capsLockKeyCode)
        }
        guard needed else {
            hid.stop()
            return
        }
        guard !hid.isOpen else { return }
        hid.onKey = { [weak self] keyCode, isDown in
            self?.handleHIDKey(keyCode: keyCode, isDown: isDown)
        }
        hid.start()
    }

    private func handleHIDKey(keyCode: Int, isDown: Bool) {
        guard !isPaused else { return }
        for (id, binding) in registrations where binding.isModifierOnly && binding.keyCode == keyCode {
            if isDown { keyDown(id) } else { keyUp(id) }
        }
        if keyCode == Shortcut.capsLockKeyCode, !isDown,
           registrations.values.contains(where: { $0.isModifierOnly && $0.keyCode == keyCode }) {
            HIDKeyMonitor.clearCapsLock()
        }
    }

    // MARK: - Mouse Buttons

    private func handleMouse(button: Int, isDown: Bool) {
        guard !isPaused else { return }
        for (id, binding) in registrations where binding.isMouseButton && binding.mouseButton == button {
            if isDown { keyDown(id) } else { keyUp(id) }
        }
    }
}

// MARK: - KeyboardShortcuts Name Extension

extension KeyboardShortcuts.Name {
    /// The single registration older builds used; cleared at start.
    static let toggleRecording = Self("toggleRecording")
}
