import AppKit
import CoreGraphics

/// A one-shot listener used by the onboarding "Hotkey" step to functionally
/// verify that Parrot can detect the dictation key. It mirrors HotkeyManager's
/// modifier detection (a session-level CGEventTap plus NSEvent monitors) but
/// only reports the first press of the target key, then can be stopped.
///
/// Rationale: on macOS 15+, `CGPreflightListenEventAccess()` is unreliable, so
/// a live "press the key and watch it light up" test is a more honest signal
/// than the preflight status alone.
final class HotkeyProbe {

    /// Called on the main actor when the target modifier key is pressed.
    var onDetected: (() -> Void)?

    /// keyCode of the modifier to watch (e.g. 0x3D for Right Option).
    private let targetKeyCode: Int

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fired = false

    init(targetKeyCode: Int) {
        self.targetKeyCode = targetKeyCode
    }

    deinit {
        stop()
    }

    func start() {
        installTap()

        // NSEvent monitors run in parallel: the global monitor uses
        // Accessibility, the local one needs no permission and fires while
        // Parrot is focused. Any path lighting up confirms detection works.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int(event.keyCode))
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int(event.keyCode))
            return event
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil

        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                if let userInfo {
                    let probe = Unmanaged<HotkeyProbe>.fromOpaque(userInfo).takeUnretainedValue()
                    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    probe.handle(keyCode: keyCode)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(keyCode: Int) {
        guard keyCode == targetKeyCode, !fired else { return }
        fired = true
        DispatchQueue.main.async { [weak self] in
            self?.onDetected?()
        }
    }
}
