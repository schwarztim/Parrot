import CoreGraphics
import Foundation

/// Owns the global hotkey listener: creates it at setup, routes presses to
/// the dictation controller, and converts saved bindings for it.
@MainActor
final class HotkeyCenter {

    /// The listener, created by `install(controller:)` at setup.
    private(set) var manager: HotkeyManager?

    private weak var controller: DictationController?

    /// Creates the listener and routes key down to start and key up to stop
    /// (hold to talk). Idempotent. Call `apply(_:)`, then `start()`.
    @discardableResult
    func install(controller: DictationController) -> HotkeyManager {
        if let manager { return manager }
        self.controller = controller

        let hotkey = HotkeyManager()
        hotkey.onKeyDown = { [weak self] in
            diagLog("[Parrot:Hotkey] onKeyDown fired!")
            Task { @MainActor in
                self?.controller?.start(trigger: .pushToTalk)
            }
        }
        hotkey.onKeyUp = { [weak self] in
            diagLog("[Parrot:Hotkey] onKeyUp fired!")
            Task { @MainActor in
                self?.controller?.stop(trigger: .pushToTalk)
            }
        }
        manager = hotkey
        return hotkey
    }

    /// Applies the saved dictation binding to the listener.
    func apply(_ settings: AppSettings) {
        guard let manager else { return }
        let binding = settings.hotkeys.hotkeyBinding

        // Guard against broken bindings saved by the old keyCode:0 capture bug.
        // A keyboard binding with keyCode 0 and no mouse button is invalid
        // (unless it's intentionally "None"/empty).
        if binding.mouseButton == nil && binding.keyCode == 0 {
            manager.binding = .rightOption
        } else {
            manager.binding = Self.toGlobalBinding(binding)
        }
    }

    /// Starts listening.
    func start() {
        manager?.start()
    }

    // MARK: - Binding Conversion

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
        default: return 0
        }
    }
}
