import Foundation

/// Which playback behavior a recording uses (au F14). [AUD]
enum PlaybackResolution {
    /// The mode's value when set, otherwise the global default. An unknown
    /// stored global value already reads as `.pause` (AudioSettings).
    static func resolve(mode: PlaybackBehavior?, global: PlaybackBehavior) -> PlaybackBehavior {
        mode ?? global
    }

    /// The output volume the behavior fades to, or nil to leave it alone.
    /// `.pause` pauses Music and Spotify and ducks everything else.
    static func targetVolume(for behavior: PlaybackBehavior, currentVolume: Float) -> Float? {
        switch behavior {
        case .keepPlaying: return nil
        case .pause, .duck: return min(currentVolume, FadeSchedule.duckedVolume)
        case .mute: return 0
        }
    }
}

extension PlaybackBehavior {
    /// Picker label.
    var label: String {
        switch self {
        case .keepPlaying: return "Keep Playing"
        case .pause: return "Pause"
        case .duck: return "Lower"
        case .mute: return "Mute"
        }
    }
}

/// One volume change in a fade, `delay` seconds after the fade starts.
struct FadeStep: Equatable {
    let delay: TimeInterval
    let volume: Float
}

/// Fade timings for ducking and muting (au F16). [AUD]
enum FadeSchedule {
    /// Ducked output volume on the 0 to 1 scale (never raised above the current volume).
    static let duckedVolume: Float = 0.15
    /// Assumed original volume when the output device cannot report one.
    static let assumedOriginalVolume: Float = 0.5
    /// A Bluetooth restore waits this long for the output device to change.
    static let bluetoothRestoreTimeout: TimeInterval = 4.0
    /// Bluetooth headsets reset their volume while switching profiles, so
    /// the final value is applied again after each of these delays.
    static let bluetoothStabilizationDelays: [TimeInterval] = [0.08, 0.18, 0.32, 0.5, 0.75]

    enum Direction {
        case fadeOut
        case fadeIn
    }

    static func timing(_ direction: Direction, bluetooth: Bool) -> (duration: TimeInterval, steps: Int) {
        switch (direction, bluetooth) {
        case (.fadeOut, false): return (0.25, 10)
        case (.fadeOut, true): return (0.4, 16)
        case (.fadeIn, false): return (0.5, 10)
        case (.fadeIn, true): return (0.65, 16)
        }
    }

    /// Evenly spaced steps from `from` to `to`; the last step lands exactly
    /// on `to` at the full duration. Bluetooth fades end with the
    /// stabilization re-applies.
    static func steps(from: Float, to: Float, direction: Direction, bluetooth: Bool) -> [FadeStep] {
        let (duration, count) = timing(direction, bluetooth: bluetooth)
        var steps = (1...count).map { index -> FadeStep in
            let fraction = Float(index) / Float(count)
            let volume = index == count ? to : from + (to - from) * fraction
            return FadeStep(delay: duration * Double(index) / Double(count), volume: volume)
        }
        if bluetooth {
            steps += bluetoothStabilizationDelays.map { FadeStep(delay: duration + $0, volume: to) }
        }
        return steps
    }
}
