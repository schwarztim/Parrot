import Foundation
import Observation

/// Agent mode settings. [AGT]
///
/// Empty for now; the AGT workstream adds its settings here. New keys are
/// named `parrot.agent.<name>`.
@Observable
final class AgentSettings {

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        self.store = store
    }
}
