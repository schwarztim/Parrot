import Foundation
import Observation

/// Dictation history settings. [DATA]
@Observable
final class HistorySettings {

    private enum Key {
        static let historyEnabled = "parrot.historyEnabled"
        static let historyRetentionDays = "parrot.historyRetentionDays"
    }

    /// When on, dictations are saved to the searchable local history. Off is the
    /// "store nothing" mode.
    var historyEnabled: Bool {
        didSet { store.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// Days to keep history. 0 keeps forever.
    var historyRetentionDays: Int {
        didSet { store.set(historyRetentionDays, forKey: Key.historyRetentionDays) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        historyEnabled = store.bool(Key.historyEnabled, default: true)
        historyRetentionDays = store.int(Key.historyRetentionDays, default: 30)
        self.store = store
    }
}
