import AppKit
import CoreGraphics
import Foundation
import Observation

extension Notification.Name {
    /// A shortcut recorder started capturing keys. Global shortcuts pause
    /// until the matching `parrotShortcutCaptureDidEnd`.
    static let parrotShortcutCaptureDidBegin = Notification.Name("parrot.hotkeys.captureDidBegin")
    static let parrotShortcutCaptureDidEnd = Notification.Name("parrot.hotkeys.captureDidEnd")
}

/// Owns the global shortcuts: registers every armed binding on the
/// listener, routes presses through `TriggerStateMachine` to the dictation
/// controller, and drives the mode switcher keys. [TRG]
///
/// Bindings follow `settings.hotkeys`, each mode's `shortcut`, the dictation
/// phase (Cancel is armed only while recording) and
/// `services.live.modeSwitcherShown` (arrows, Return and digits are armed
/// only while the switcher shows); changes re-register automatically.
@MainActor
final class HotkeyCenter {

    /// The listener, created by `install(controller:)` at setup.
    private(set) var manager: HotkeyManager?

    /// What is registered right now.
    private(set) var plan = HotkeyPlan()

    /// Runs instead of cancelling when the cancel key is pressed during a
    /// recording, for example to show the recorder's discard confirmation.
    /// The cancel key always closes a shown mode switcher first.
    var cancelHandler: (@MainActor () -> Void)?

    private weak var controller: DictationController?
    private var settings: AppSettings?
    private var machine = TriggerStateMachine()
    private var isObserving = false
    private var modeBeforeSwitcher: UUID?
    private var captureCount = 0
    private var captureObservers: [NSObjectProtocol] = []

    private var services: AppServices? { controller?.services }

    /// Creates the listener and routes its presses to the controller.
    /// Idempotent. Call `apply(_:)`, then `start()`.
    @discardableResult
    func install(controller: DictationController) -> HotkeyManager {
        if let manager { return manager }
        self.controller = controller

        let hotkey = HotkeyManager()
        hotkey.onEvent = { [weak self] id, event in
            Task { @MainActor in
                self?.handle(id: id, event: event)
            }
        }
        manager = hotkey
        observeCapture()
        return hotkey
    }

    /// Carries old bindings over once, registers the current ones, and keeps
    /// them in sync with settings, modes and the dictation phase from now on.
    func apply(_ settings: AppSettings) {
        self.settings = settings
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: settings.general.hasCompletedOnboarding)
        refresh()
        if !isObserving {
            isObserving = true
            track()
        }
    }

    /// Starts listening.
    func start() {
        manager?.start()
    }

    /// Recomputes what is armed and pushes it to the listener.
    func refresh() {
        let plan = currentPlan()
        self.plan = plan
        var options: [TriggerSource: TriggerOptions] = [:]
        var bindings: [String: HotkeyManager.GlobalHotkeyBinding] = [:]
        for (target, shortcut) in plan.bindings {
            guard let global = Self.globalBinding(for: shortcut) else { continue }
            bindings[target.registrationID] = global
            if let source = Self.source(for: target) {
                options[source] = TriggerOptions(isModifierOnly: shortcut.isModifierOnly, doubleTap: shortcut.doubleTap)
            }
        }
        machine.options = options
        machine.pushToTalkSharesToggleKey = plan.pushToTalkSharesToggleKey
        manager?.setBindings(bindings)
    }

    // MARK: - Mode Switcher

    /// True while the mode switcher shows. UI renders it from
    /// `services.live.modeSwitcherShown`; the highlighted row is
    /// `services.modes.selectedMode`.
    var isModeSwitcherShown: Bool { services?.live.modeSwitcherShown ?? false }

    func toggleModeSwitcher() {
        if isModeSwitcherShown {
            dismissModeSwitcher(restoringSelection: false)
        } else {
            showModeSwitcher()
        }
    }

    func showModeSwitcher() {
        guard let services, !services.live.modeSwitcherShown else { return }
        modeBeforeSwitcher = services.modes?.selectedMode.id
        services.live.modeSwitcherShown = true
    }

    /// Closes the switcher. With `restoringSelection` (Escape) the mode from
    /// before it opened comes back; otherwise the highlighted mode stays.
    func dismissModeSwitcher(restoringSelection: Bool) {
        guard let services, services.live.modeSwitcherShown else { return }
        if restoringSelection, let id = modeBeforeSwitcher,
           let mode = services.modes?.modes.first(where: { $0.id == id }) {
            select(mode)
        }
        modeBeforeSwitcher = nil
        services.live.modeSwitcherShown = false
    }

    /// Arrow keys: moves the selection, wrapping around.
    func moveSwitcherSelection(by delta: Int) {
        guard isModeSwitcherShown, let modeManager = services?.modes else { return }
        let modes = modeManager.modes
        let current = modes.firstIndex { $0.id == modeManager.selectedMode.id }
        guard let index = ModeSwitcherNavigation.index(from: current, moving: delta, count: modes.count) else { return }
        select(modes[index])
    }

    /// Digit keys: slot 0 (key 1) through 9 (key 0) picks that mode and
    /// closes the switcher.
    func chooseSwitcherSlot(_ slot: Int) {
        guard isModeSwitcherShown, let modes = services?.modes?.modes,
              let index = ModeSwitcherNavigation.index(forSlot: slot, count: modes.count) else { return }
        select(modes[index])
        dismissModeSwitcher(restoringSelection: false)
    }

    /// Makes `mode` the selected mode.
    func select(_ mode: Mode) {
        guard let modeManager = services?.modes else { return }
        modeManager.selectMode(mode)
        // AppState keeps its own copy of the selection for its views.
        (controller?.delegate as? AppState)?.currentMode = modeManager.selectedMode
    }

    // MARK: - Presses

    private func handle(id: String, event: HotkeyManager.Event) {
        guard let target = ShortcutTarget(registrationID: id) else { return }
        if let source = Self.source(for: target) {
            feed(source, event)
            return
        }
        guard event == .down, case .name(let name) = target else { return }
        switch name {
        case .changeMode: toggleModeSwitcher()
        case .cancelRecording: cancelPressed()
        case .navigateUp: moveSwitcherSelection(by: -1)
        case .navigateDown: moveSwitcherSelection(by: 1)
        case .actionSubmit: dismissModeSwitcher(restoringSelection: false)
        default:
            if let slot = name.modeSlot { chooseSwitcherSlot(slot) }
        }
    }

    private func feed(_ source: TriggerSource, _ event: HotkeyManager.Event) {
        guard let controller else { return }
        let input: TriggerInput
        switch event {
        case .down: input = .down(source)
        case .up: input = .up(source)
        case .interrupted: input = .interrupted(source)
        }
        guard let command = machine.handle(input, status: Self.status(of: controller)) else { return }
        diagLog("[Parrot:Hotkey] \(source) \(event) -> \(command)")
        switch command {
        case .start(let trigger, let modeID):
            var mode: Mode?
            if let modeID, let match = services?.modes?.modes.first(where: { $0.id == modeID }) {
                select(match)
                mode = match
            }
            controller.start(trigger: trigger, modeOverride: mode)
        case .stop(let trigger):
            controller.stop(trigger: trigger)
        case .cancel:
            controller.cancel()
        }
    }

    private func cancelPressed() {
        if isModeSwitcherShown {
            dismissModeSwitcher(restoringSelection: true)
            return
        }
        guard let controller, controller.phase == .starting || controller.phase == .recording else { return }
        if let cancelHandler {
            cancelHandler()
        } else {
            controller.cancel()
        }
    }

    static func status(of controller: DictationController) -> TriggerRecordingStatus {
        switch controller.phase {
        case .idle: return .idle
        case .starting, .recording: return .active(controller.session?.trigger ?? .menu)
        case .stopping, .processing: return .busy
        }
    }

    // MARK: - Observation

    private func currentPlan() -> HotkeyPlan {
        guard let settings else { return HotkeyPlan() }
        let modes = (services?.modes?.modes ?? []).compactMap { mode in
            mode.shortcut.map { (id: mode.id, shortcut: Shortcut(mode: $0)) }
        }
        let phase = services?.live.phase ?? .idle
        return ShortcutRegistry.plan(
            shortcuts: settings.hotkeys.allShortcuts,
            modes: modes,
            isRecording: phase == .starting || phase == .recording,
            switcherShown: services?.live.modeSwitcherShown ?? false
        )
    }

    /// Re-registers whenever anything `currentPlan()` reads changes.
    private func track() {
        withObservationTracking {
            _ = currentPlan()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.track()
            }
        }
    }

    private func observeCapture() {
        let center = NotificationCenter.default
        captureObservers = [
            center.addObserver(forName: .parrotShortcutCaptureDidBegin, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setCapturing(true) }
            },
            center.addObserver(forName: .parrotShortcutCaptureDidEnd, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setCapturing(false) }
            },
        ]
    }

    private func setCapturing(_ capturing: Bool) {
        captureCount = max(0, captureCount + (capturing ? 1 : -1))
        manager?.isPaused = captureCount > 0
    }

    // MARK: - Binding Conversion

    /// The press source for a target that drives recording, or nil for the
    /// switcher and cancel keys.
    nonisolated static func source(for target: ShortcutTarget) -> TriggerSource? {
        switch target {
        case .name(.pushToTalk): return .pushToTalk
        case .name(.toggleRecording): return .toggleRecording
        case .name(.clickToTalk): return .clickToTalk
        case .mode(let id): return .mode(id)
        case .name: return nil
        }
    }

    /// Converts a saved shortcut to the listener's form. Nil when empty.
    /// A binding with several mouse buttons registers the first.
    nonisolated static func globalBinding(for shortcut: Shortcut) -> HotkeyManager.GlobalHotkeyBinding? {
        if let button = shortcut.mouseButtons.first {
            return HotkeyManager.GlobalHotkeyBinding(
                keyCode: 0,
                modifierFlags: 0,
                isModifierOnly: false,
                isMouseButton: true,
                mouseButton: button
            )
        }
        guard let keyCode = shortcut.keyCode else { return nil }
        if shortcut.isModifierOnly {
            return HotkeyManager.GlobalHotkeyBinding(
                keyCode: keyCode,
                modifierFlags: modifierFlagForKeyCode(UInt16(keyCode)),
                isModifierOnly: true
            )
        }
        return HotkeyManager.GlobalHotkeyBinding(
            keyCode: keyCode,
            modifierFlags: UInt64(shortcut.modifiers),
            isModifierOnly: false
        )
    }

    /// Converts a UI-level HotkeyBinding to the CGEvent-level GlobalHotkeyBinding.
    nonisolated static func toGlobalBinding(_ binding: HotkeyBinding) -> HotkeyManager.GlobalHotkeyBinding {
        // Mouse button binding
        if let mouse = binding.mouseButton {
            return HotkeyManager.GlobalHotkeyBinding(
                keyCode: 0,
                modifierFlags: 0,
                isModifierOnly: false,
                isMouseButton: true,
                mouseButton: mouse
            )
        }

        let modifierKeyCodes: Set<UInt16> = [
            0x3A, 0x3D, // Left/Right Option
            0x37, 0x36, // Left/Right Command
            0x38, 0x3C, // Left/Right Shift
            0x3B, 0x3E, // Left/Right Control
        ]
        let isModOnly = modifierKeyCodes.contains(binding.keyCode)

        let flags: UInt64
        if isModOnly {
            flags = modifierFlagForKeyCode(binding.keyCode)
        } else {
            flags = binding.cgEventFlags.rawValue
        }

        return HotkeyManager.GlobalHotkeyBinding(
            keyCode: Int(binding.keyCode),
            modifierFlags: flags,
            isModifierOnly: isModOnly
        )
    }

    private nonisolated static func modifierFlagForKeyCode(_ keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 0x3A, 0x3D: return CGEventFlags.maskAlternate.rawValue
        case 0x37, 0x36: return CGEventFlags.maskCommand.rawValue
        case 0x38, 0x3C: return CGEventFlags.maskShift.rawValue
        case 0x3B, 0x3E: return CGEventFlags.maskControl.rawValue
        case 0x3F: return CGEventFlags.maskSecondaryFn.rawValue
        case 0x39: return CGEventFlags.maskAlphaShift.rawValue
        default: return 0
        }
    }
}
