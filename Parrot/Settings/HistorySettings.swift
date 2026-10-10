import Foundation
import Observation

/// Dictation history settings. [DATA]
@Observable
final class HistorySettings {

    private enum Key {
        static let historyEnabled = "parrot.historyEnabled"
        static let historyRetentionDays = "parrot.historyRetentionDays"
        static let savePromptContext = "parrot.history.savePromptContext"
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

    /// Store the rendered prompt and captured context in each recording's
    /// `meta.json`. Off by default: both can hold selected text and other
    /// sensitive context.
    var savePromptContext: Bool {
        didSet { store.set(savePromptContext, forKey: Key.savePromptContext) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        historyEnabled = store.bool(Key.historyEnabled, default: true)
        historyRetentionDays = store.int(Key.historyRetentionDays, default: 0)
        savePromptContext = store.bool(Key.savePromptContext, default: false)
        self.store = store
    }
}
