import Foundation
import Observation

/// Microphone and sound effect settings. [AUD]
@Observable
final class AudioSettings {

    private enum Key {
        static let autoMicVolume = "parrot.autoMicVolume"
        static let soundEffectsEnabled = "parrot.soundEffectsEnabled"
        static let soundEffectsVolume = "parrot.soundEffectsVolume"
        static let selectedInputDeviceID = "parrot.selectedInputDeviceID"
    }

    var autoMicVolume: Bool {
        didSet { store.set(autoMicVolume, forKey: Key.autoMicVolume) }
    }

    var soundEffectsEnabled: Bool {
        didSet { store.set(soundEffectsEnabled, forKey: Key.soundEffectsEnabled) }
    }

    var soundEffectsVolume: Double {
        didSet { store.set(soundEffectsVolume, forKey: Key.soundEffectsVolume) }
    }

    /// The chosen microphone. Nil follows the system default input.
    var selectedInputDeviceID: String? {
        didSet { store.set(selectedInputDeviceID, forKey: Key.selectedInputDeviceID) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        autoMicVolume = store.bool(Key.autoMicVolume, default: true)
        soundEffectsEnabled = store.bool(Key.soundEffectsEnabled, default: true)
        soundEffectsVolume = store.double(Key.soundEffectsVolume, default: 0.7)
        selectedInputDeviceID = store.string(Key.selectedInputDeviceID)
        self.store = store
    }
}
