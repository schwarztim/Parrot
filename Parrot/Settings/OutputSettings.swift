import Foundation
import Observation

/// How text is delivered to the destination app. [OUT]
@Observable
final class OutputSettings {

    private enum Key {
        static let autoPaste = "parrot.output.autoPaste"
        static let clipboardBehaviour = "parrot.output.clipboardBehaviour"
        static let restoreDelay = "parrot.output.restoreDelay"
        static let clipboardHistory = "parrot.output.clipboardHistory"
        static let simulateKeypresses = "parrot.output.simulateKeypresses"
        static let autoSubmitWithShift = "parrot.output.autoSubmitWithShift"
    }

    /// Paste the result into the focused field. A mode's `autoPaste`
    /// overrides it. When off, the text is left on the clipboard.
    var autoPaste: Bool {
        didSet { store.set(autoPaste, forKey: Key.autoPaste) }
    }

    /// What the clipboard holds after a paste. Stored as `keep` or `replace`.
    var clipboardBehaviour: ClipboardBehaviour {
        didSet { store.set(clipboardBehaviour, forKey: Key.clipboardBehaviour) }
    }

    /// Seconds after a paste before the user's clipboard goes back. Not
    /// shown in the settings UI.
    var restoreDelay: Double {
        didSet { store.set(restoreDelay, forKey: Key.restoreDelay) }
    }

    /// Let clipboard history apps keep dictations. Off marks them transient.
    var clipboardHistory: Bool {
        didSet { store.set(clipboardHistory, forKey: Key.clipboardHistory) }
    }

    /// Type the result as key presses instead of pasting (US QWERTY only).
    var simulateKeypresses: Bool {
        didSet { store.set(simulateKeypresses, forKey: Key.simulateKeypresses) }
    }

    /// Press Return after the paste when Shift is held as the recording stops.
    var autoSubmitWithShift: Bool {
        didSet { store.set(autoSubmitWithShift, forKey: Key.autoSubmitWithShift) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        autoPaste = store.bool(Key.autoPaste, default: true)
        clipboardBehaviour = store.value(Key.clipboardBehaviour, default: ClipboardBehaviour.keep)
        restoreDelay = store.double(Key.restoreDelay, default: 1.0)
        clipboardHistory = store.bool(Key.clipboardHistory, default: false)
        simulateKeypresses = store.bool(Key.simulateKeypresses, default: false)
        autoSubmitWithShift = store.bool(Key.autoSubmitWithShift, default: false)
        self.store = store
    }
}
