import Foundation
import Observation

/// Dictation history settings. [DATA]
@Observable
final class HistorySettings {

    private enum Key {
        static let historyEnabled = "parrot.historyEnabled"
        static let historyRetentionDays = "parrot.historyRetentionDays"
        static let savePromptContext = "parrot.history.savePromptContext"
        /// Owned by GeneralSettings (UI); read here for time saved.
        static let typingWPM = "parrot.general.typingWPM"
    }

    /// Typing speed used for "time saved" until the user sets one.
    static let defaultTypingWPM: Double = 40

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

    /// Words per minute the user types, for "time saved". Read from the
    /// General area's key; 40 when unset.
    var typingWPM: Double {
        let value = store.double(Key.typingWPM, default: Self.defaultTypingWPM)
        return value > 0 ? value : Self.defaultTypingWPM
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        historyEnabled = store.bool(Key.historyEnabled, default: true)
        historyRetentionDays = store.int(Key.historyRetentionDays, default: 30)
        savePromptContext = store.bool(Key.savePromptContext, default: false)
        self.store = store
    }
}
