import CoreAudio
import Foundation

/// One audio input device. `uid` is the persistent Core Audio UID that
/// settings store; `id` is the numeric id, valid only until the device or
/// the audio system restarts. [AUD]
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    /// A MacBook's own microphone, which goes deaf with the lid closed.
    var isBuiltInMic: Bool { DeviceResolver.isBuiltInMicName(name) }
}

/// Picks the input device for a recording (au F1 to F5). Pure: callers pass
/// the connected devices and the settings, so every branch is testable
/// without Core Audio. [AUD]
enum DeviceResolver {

    /// Virtual meeting drivers that loop other apps' audio back as an
    /// "input". They are never picked automatically or shown as choices.
    static let builtInExcludedUIDs: Set<String> = ["MSLoopbackDriverDevice_UID"]
    /// The same drivers matched by name, for versions with other UIDs.
    static let builtInExcludedNames: [String] = ["Microsoft Teams Audio", "ZoomAudioDevice"]

    static let builtInMicNames: Set<String> = [
        "MacBook Pro Microphone", "MacBook Air Microphone", "MacBook Microphone",
    ]

    static func isBuiltInMicName(_ name: String) -> Bool {
        builtInMicNames.contains(name)
    }

    /// True for the virtual meeting drivers above.
    static func isBuiltInExcluded(_ device: AudioDevice) -> Bool {
        builtInExcludedUIDs.contains(device.uid)
            || builtInExcludedNames.contains { device.name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - Resolution

    struct Inputs: Equatable {
        /// Connected input devices in system order.
        var devices: [AudioDevice]
        /// UID of the macOS default input, if it could be read.
        var defaultUID: String?
        var useDefault: Bool
        var pinnedUID: String?
        var userExcluded: Set<String> = []
        var selectionCounts: [String: Int] = [:]
        var lidClosed = false
    }

    enum Reason: Equatable {
        case systemDefault
        /// The default input is excluded; first other device used.
        case defaultExcluded
        /// Lid closed and the choice was the built-in mic; an external one is used.
        case lidClosedExternal
        /// Lid closed, the choice is the built-in mic and nothing else exists.
        case lidClosedBuiltIn
        case pinned
        /// The pinned device is not connected; the most selected one is used.
        case fallbackMostSelected(count: Int)
        /// The pinned device is not connected and nothing was selected before.
        case fallbackDefault
        case lastResort
        case noDevices
    }

    struct Resolution: Equatable {
        var device: AudioDevice?
        var reason: Reason
        /// The pinned device is excluded, so the setting should go back to
        /// following the system default.
        var resetToDefault = false

        /// The capture would use the built-in mic while the lid is closed.
        var needsLidWarning: Bool { reason == .lidClosedBuiltIn }
    }

    static func isExcluded(_ device: AudioDevice, userExcluded: Set<String>) -> Bool {
        userExcluded.contains(device.uid) || isBuiltInExcluded(device)
    }

    /// Resolution order: pinned device, then the most selected connected
    /// device, then the system default, then any device. With the lid closed
    /// an external device replaces the built-in mic when one exists.
    static func resolve(_ inputs: Inputs) -> Resolution {
        let available = inputs.devices.filter { !isExcluded($0, userExcluded: inputs.userExcluded) }

        if !inputs.useDefault, let pin = inputs.pinnedUID {
            if inputs.userExcluded.contains(pin) || builtInExcludedUIDs.contains(pin) {
                var resolution = resolveDefault(inputs, available: available, plainReason: .systemDefault)
                resolution.resetToDefault = true
                return resolution
            }
            if let pinned = inputs.devices.first(where: { $0.uid == pin }) {
                if isExcluded(pinned, userExcluded: inputs.userExcluded) {
                    var resolution = resolveDefault(inputs, available: available, plainReason: .systemDefault)
                    resolution.resetToDefault = true
                    return resolution
                }
                return avoidingBuiltIn(pinned, reason: .pinned, inputs: inputs, available: available)
            }
            if let best = mostSelected(available, counts: inputs.selectionCounts) {
                let count = inputs.selectionCounts[best.uid] ?? 0
                return avoidingBuiltIn(best, reason: .fallbackMostSelected(count: count), inputs: inputs, available: available)
            }
            return resolveDefault(inputs, available: available, plainReason: .fallbackDefault)
        }
        return resolveDefault(inputs, available: available, plainReason: .systemDefault)
    }

    private static func resolveDefault(_ inputs: Inputs, available: [AudioDevice], plainReason: Reason) -> Resolution {
        guard let defaultUID = inputs.defaultUID,
              let systemDefault = inputs.devices.first(where: { $0.uid == defaultUID })
        else {
            return lastResort(inputs, available: available)
        }
        if isExcluded(systemDefault, userExcluded: inputs.userExcluded) {
            if let first = available.first {
                return avoidingBuiltIn(first, reason: .defaultExcluded, inputs: inputs, available: available)
            }
            return lastResort(inputs, available: available)
        }
        return avoidingBuiltIn(systemDefault, reason: plainReason, inputs: inputs, available: available)
    }

    private static func lastResort(_ inputs: Inputs, available: [AudioDevice]) -> Resolution {
        if let first = available.first ?? inputs.devices.first {
            return avoidingBuiltIn(first, reason: .lastResort, inputs: inputs, available: available)
        }
        return Resolution(device: nil, reason: .noDevices)
    }

    /// With the lid closed, swaps the built-in mic for an external device
    /// (most selected first, then system order).
    private static func avoidingBuiltIn(
        _ device: AudioDevice, reason: Reason, inputs: Inputs, available: [AudioDevice]
    ) -> Resolution {
        guard inputs.lidClosed, device.isBuiltInMic else {
            return Resolution(device: device, reason: reason)
        }
        if let external = externalDevice(available, counts: inputs.selectionCounts) {
            return Resolution(device: external, reason: .lidClosedExternal)
        }
        return Resolution(device: device, reason: .lidClosedBuiltIn)
    }

    static func externalDevice(_ available: [AudioDevice], counts: [String: Int]) -> AudioDevice? {
        let externals = available.filter { !$0.isBuiltInMic }
        return mostSelected(externals, counts: counts) ?? externals.first
    }

    /// The device with the highest selection count above zero; ties go to
    /// system order.
    static func mostSelected(_ devices: [AudioDevice], counts: [String: Int]) -> AudioDevice? {
        var best: AudioDevice?
        var bestCount = 0
        for device in devices {
            let count = counts[device.uid] ?? 0
            if count > bestCount {
                best = device
                bestCount = count
            }
        }
        return best
    }

    // MARK: - Auto-select on connect

    enum AutoSelectReason: Equatable {
        /// A priority device connected (the most recently marked wins).
        case priority
        /// A device chosen more often than the current one connected.
        case higherCount(Int)
    }

    /// The device to switch to when `newlyConnected` devices appear, or nil
    /// to keep the current choice.
    static func autoSelect(
        newlyConnected: [AudioDevice],
        currentUID: String?,
        priority: [String: Double],
        counts: [String: Int],
        userExcluded: Set<String>
    ) -> (device: AudioDevice, reason: AutoSelectReason)? {
        let candidates = newlyConnected.filter {
            !isExcluded($0, userExcluded: userExcluded) && $0.uid != currentUID
        }
        let prioritized = candidates.filter { priority[$0.uid] != nil }
        if let newest = prioritized.max(by: { (priority[$0.uid] ?? 0) < (priority[$1.uid] ?? 0) }) {
            return (newest, .priority)
        }
        let currentCount = currentUID.flatMap { counts[$0] } ?? 0
        let better = candidates.filter { (counts[$0.uid] ?? 0) > currentCount }
        if let best = mostSelected(better, counts: counts) {
            return (best, .higherCount(counts[best.uid] ?? 0))
        }
        return nil
    }

    // MARK: - Migration

    /// Older builds could store the numeric device id. Returns the UID to
    /// store instead, `.some(nil)` to drop an id that no longer maps to a
    /// device, or nil when the stored value is already a UID.
    static func migratedPin(stored: String?, devices: [AudioDevice]) -> String?? {
        guard let stored, let numeric = AudioDeviceID(stored) else { return nil }
        if let device = devices.first(where: { $0.id == numeric }) {
            return .some(device.uid)
        }
        return .some(nil)
    }
}
