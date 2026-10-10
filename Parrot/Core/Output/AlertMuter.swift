import Foundation

/// Reads and sets the system alert (beep) volume, 0 to 100. [OUT]
@MainActor
protocol AlertVolumeControl: AnyObject {
    func read() -> Int?
    func set(_ volume: Int)
}

/// The alert volume through Standard Additions (`get volume settings`).
@MainActor
final class AppleScriptAlertVolume: AlertVolumeControl {
    private lazy var readScript = NSAppleScript(source: "alert volume of (get volume settings)")

    init() {}

    func read() -> Int? {
        var error: NSDictionary?
        guard let result = readScript?.executeAndReturnError(&error), error == nil else { return nil }
        return Int(result.int32Value)
    }

    func set(_ volume: Int) {
        var error: NSDictionary?
        NSAppleScript(source: "set volume alert volume \(max(0, min(100, volume)))")?.executeAndReturnError(&error)
    }
}

/// Silences the alert sound for a short window around synthetic key
/// presses, so a paste where nothing accepts text does not beep. Overlapping
/// windows merge, and the user's volume is read once and always put back.
/// [OUT]
@MainActor
final class AlertMuter {
    private let control: AlertVolumeControl
    private let scheduler: DelayScheduler
    private var originalVolume: Int?
    private var restoreWork: ScheduledWork?

    init(control: AlertVolumeControl, scheduler: DelayScheduler) {
        self.control = control
        self.scheduler = scheduler
    }

    /// True while the alert volume is held at 0 by this muter.
    var isMuted: Bool { originalVolume != nil }

    /// Mutes now (if not already) and restores `duration` seconds from now.
    func muteBriefly(for duration: TimeInterval = 0.6) {
        if originalVolume == nil {
            guard let volume = control.read(), volume > 0 else { return }
            originalVolume = volume
            control.set(0)
            diagLog("[Parrot:Output] Muted alert volume, original: \(volume)")
        }
        restoreWork?.cancel()
        restoreWork = scheduler.schedule(after: duration) { [weak self] in
            self?.restore()
        }
    }

    /// Puts the user's volume back now.
    func restore() {
        restoreWork?.cancel()
        restoreWork = nil
        guard let volume = originalVolume else { return }
        originalVolume = nil
        control.set(volume)
        diagLog("[Parrot:Output] Alert volume restored to \(volume)")
    }
}
