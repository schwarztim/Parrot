import Foundation
import Observation

// MARK: - AppSettings

/// Every settings area, built from one `SettingsStore` and one
/// `SecretStore`. Frozen: each area lives in its own file under `Settings/`
/// and its owner adds properties there.
///
/// Only `appSettings` is in the SwiftUI environment. Views bind an area with
/// `@Bindable var audio = appSettings.audio` or read `appSettings.audio.x`;
/// Observation tracks the nested reads.
///
/// Tests build one with a suite-named `UserDefaults` and an
/// `InMemorySecretStore`, never with `AppSettings()`.
@Observable
final class AppSettings {

    let general: GeneralSettings
    let recorder: RecorderSettings
    let hotkeys: HotkeySettings
    let output: OutputSettings
    let audio: AudioSettings
    let transcription: TranscriptionSettings
    let refinement: RefinementSettings
    let credentials: ProviderCredentials
    let history: HistorySettings
    let vocabulary: VocabularySettings
    let agent: AgentSettings

    init(store: SettingsStore, secrets: SecretStore) {
        general = GeneralSettings(store: store)
        recorder = RecorderSettings(store: store)
        hotkeys = HotkeySettings(store: store)
        output = OutputSettings(store: store)
        audio = AudioSettings(store: store)
        transcription = TranscriptionSettings(store: store)
        // Refinement first: its legacy migration moves the old enhance key
        // into the Azure item that credentials then loads.
        refinement = RefinementSettings(store: store, secrets: secrets)
        credentials = ProviderCredentials(store: store, secrets: secrets)
        history = HistorySettings(store: store)
        vocabulary = VocabularySettings(store: store)
        agent = AgentSettings(store: store, secrets: secrets)
    }

    /// Production settings: standard user defaults and the Keychain.
    convenience init() {
        self.init(store: SettingsStore(), secrets: KeychainSecretStore())
    }

    // MARK: - Cross-Area

    /// Whether to show the one-time AI Refinement discovery card on Home.
    var shouldShowRefinementNudge: Bool {
        !general.refinementNudgeDismissed && !refinement.refinementEnabled && general.successfulDictationCount >= 5
    }
}
