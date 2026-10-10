import Foundation
import Observation

/// How text is delivered to the destination app. [OUT]
///
/// Empty for now; the OUT workstream adds its settings here. New keys are
/// named `parrot.output.<name>`.
@Observable
final class OutputSettings {

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        self.store = store
    }
}
