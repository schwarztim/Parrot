import Foundation
import Observation

/// Custom vocabulary settings. [DATA]
@Observable
final class VocabularySettings {

    private enum Key {
        static let vocabularyBoostingEnabled = "parrot.vocabularyBoostingEnabled"
    }

    /// When on, vocabulary terms bias the recognizer at decode time (downloads
    /// an auxiliary CTC model). Off by default because of the extra download.
    var vocabularyBoostingEnabled: Bool {
        didSet { store.set(vocabularyBoostingEnabled, forKey: Key.vocabularyBoostingEnabled) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        vocabularyBoostingEnabled = store.bool(Key.vocabularyBoostingEnabled, default: false)
        self.store = store
    }
}
