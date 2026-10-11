import Foundation
import Observation

/// Microphone, playback and sound effect settings. [AUD]
@Observable
final class AudioSettings {

    private enum Key {
        static let autoMicVolume = "parrot.autoMicVolume"
        static let soundEffectsEnabled = "parrot.soundEffectsEnabled"
        static let soundEffectsVolume = "parrot.soundEffectsVolume"
        static let selectedInputDeviceID = "parrot.selectedInputDeviceID"
        static let useDefaultDevice = "parrot.audio.useDefaultDevice"
        static let excludedDevices = "parrot.audio.excludedDevices"
        static let selectionCounts = "parrot.audio.selectionCounts"
        static let priorityDevices = "parrot.audio.priorityDevices"
        static let playbackBehavior = "parrot.audio.playbackBehavior"
        static let soundTheme = "parrot.audio.soundTheme"
    }

    /// Sets the default input device's volume to maximum when a recording
    /// starts. Only applies while following the system default device.
    var autoMicVolume: Bool {
        didSet { store.set(autoMicVolume, forKey: Key.autoMicVolume) }
    }

    /// Off in the sound effects picker sets this false.
    var soundEffectsEnabled: Bool {
        didSet { store.set(soundEffectsEnabled, forKey: Key.soundEffectsEnabled) }
    }

    var soundEffectsVolume: Double {
        didSet { store.set(soundEffectsVolume, forKey: Key.soundEffectsVolume) }
    }

    /// The pinned microphone's Core Audio UID, used while
    /// `useDefaultDevice` is false. Nil follows the system default input.
    var selectedInputDeviceID: String? {
        didSet { store.set(selectedInputDeviceID, forKey: Key.selectedInputDeviceID) }
    }

    /// Follow the macOS default input instead of the pinned device.
    var useDefaultDevice: Bool {
        didSet { store.set(useDefaultDevice, forKey: Key.useDefaultDevice) }
    }

    /// Devices hidden from the picker and from automatic selection, UID to
    /// display name (kept while disconnected so they can be restored).
    var excludedDevices: [String: String] {
        didSet { store.setEncoded(excludedDevices.isEmpty ? nil : excludedDevices, forKey: Key.excludedDevices) }
    }

    /// Manual selections per device UID.
    var selectionCounts: [String: Int] {
        didSet { store.setEncoded(selectionCounts.isEmpty ? nil : selectionCounts, forKey: Key.selectionCounts) }
    }

    /// Priority devices, UID to the unix time they were marked. A priority
    /// device is selected as soon as it connects.
    var priorityDevices: [String: Double] {
        didSet { store.setEncoded(priorityDevices.isEmpty ? nil : priorityDevices, forKey: Key.priorityDevices) }
    }

    /// What other audio does while recording, unless the mode overrides it.
    var playbackBehavior: PlaybackBehavior {
        didSet { store.set(playbackBehavior, forKey: Key.playbackBehavior) }
    }

    var soundTheme: SoundTheme {
        didSet { store.set(soundTheme, forKey: Key.soundTheme) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        autoMicVolume = store.bool(Key.autoMicVolume, default: true)
        soundEffectsEnabled = store.bool(Key.soundEffectsEnabled, default: true)
        soundEffectsVolume = store.double(Key.soundEffectsVolume, default: 0.7)
        let selected = store.string(Key.selectedInputDeviceID)
        selectedInputDeviceID = selected
        // Before this key existed, a stored device meant "pinned".
        useDefaultDevice = store.contains(Key.useDefaultDevice)
            ? store.bool(Key.useDefaultDevice, default: true)
            : selected == nil
        excludedDevices = store.decoded([String: String].self, forKey: Key.excludedDevices) ?? [:]
        selectionCounts = store.decoded([String: Int].self, forKey: Key.selectionCounts) ?? [:]
        priorityDevices = store.decoded([String: Double].self, forKey: Key.priorityDevices) ?? [:]
        playbackBehavior = store.value(Key.playbackBehavior, default: .pause)
        soundTheme = store.value(Key.soundTheme, default: .simple)
        self.store = store
    }
}
