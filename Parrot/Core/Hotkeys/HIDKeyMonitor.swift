import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Reads Fn/Globe and Caps Lock straight from the keyboards through IOHID,
/// with real key down and key up events. [TRG]
///
/// Neither key reaches the system hot key API, and Caps Lock only reports a
/// state change (no release) through flagsChanged. Opening the HID manager
/// needs Input Monitoring; without it `start()` returns false and
/// HotkeyManager falls back to its flagsChanged path.
final class HIDKeyMonitor {

    /// Called on the main thread with a virtual key code
    /// (`Shortcut.functionKeyCode` or `Shortcut.capsLockKeyCode`) and
    /// whether the key is now down.
    var onKey: ((Int, Bool) -> Void)?

    private(set) var isOpen = false
    private var manager: IOHIDManager?
    /// Last state per key code, so duplicate reports from several
    /// keyboards and a lost release cannot latch a key.
    private var lastState: [Int: Bool] = [:]

    deinit {
        stop()
    }

    /// Opens every keyboard. Returns false (and logs) when the manager
    /// cannot be opened, for example without Input Monitoring.
    @discardableResult
    func start() -> Bool {
        if manager != nil { return isOpen }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let devices: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
            [kIOHIDDeviceUsagePageKey: Self.appleVendorTopCasePage],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, devices as CFArray)

        let inputs: [[String: Int]] = [
            [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad, kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock],
            [kIOHIDElementUsagePageKey: Self.appleVendorTopCasePage, kIOHIDElementUsageKey: Self.appleFnUsage],
            [kIOHIDElementUsagePageKey: Self.appleVendorKeyboardPage, kIOHIDElementUsageKey: Self.appleFnUsage],
        ]
        IOHIDManagerSetInputValueMatchingMultiple(manager, inputs as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDKeyMonitor>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        isOpen = result == kIOReturnSuccess
        if isOpen {
            diagLog("[Parrot:HID] HID manager open (Fn, Caps Lock)")
        } else {
            diagLog("[Parrot:HID] Failed to open HID manager with code \(result); using flagsChanged instead")
            stop()
        }
        return isOpen
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if isOpen { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        self.manager = nil
        isOpen = false
        lastState = [:]
    }

    /// Records a release seen elsewhere (flagsChanged without the Fn bit),
    /// so a release the HID stream lost cannot keep Fn down.
    func noteReleased(_ keyCode: Int) {
        guard lastState[keyCode] == true else { return }
        lastState[keyCode] = false
        onKey?(keyCode, false)
    }

    /// Turns the Caps Lock state off, so using Caps Lock as a shortcut does
    /// not leave capitals on.
    static func clearCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return
        }
        defer { IOServiceClose(connect) }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
    }

    // MARK: - Private

    private static let appleVendorTopCasePage = 0xFF
    private static let appleVendorKeyboardPage = 0xFF01
    private static let appleFnUsage = 0x03

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let keyCode: Int
        switch (page, usage) {
        case (kHIDPage_KeyboardOrKeypad, kHIDUsage_KeyboardCapsLock):
            keyCode = Shortcut.capsLockKeyCode
        case (Self.appleVendorTopCasePage, Self.appleFnUsage), (Self.appleVendorKeyboardPage, Self.appleFnUsage):
            keyCode = Shortcut.functionKeyCode
        default:
            diagLog("[Parrot:HID] HID usage not mapped: page=\(page) usage=\(usage)")
            return
        }
        let isDown = IOHIDValueGetIntegerValue(value) != 0
        guard lastState[keyCode] != isDown else { return }
        lastState[keyCode] = isDown
        onKey?(keyCode, isDown)
    }
}
