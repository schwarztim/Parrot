import Foundation
import Observation

/// Agent mode settings: answering Claude Code and Codex from Parrot. [AGT]
///
/// Which CLIs have Parrot's hooks installed is not stored; the Agents tab
/// reads each CLI's own settings file to find out.
@Observable
final class AgentSettings {

    private enum Key {
        static let enabled = "parrot.agent.enabled"
        static let responseTimeout = "parrot.agent.responseTimeout"
    }

    /// Seconds the hook helper may wait for an answer, at most.
    static let timeoutRange: ClosedRange<Double> = 30...3600

    /// Show agent requests in Parrot. Off, the hook helper exits at once and
    /// the CLIs ask in the terminal as usual.
    var enabled: Bool {
        didSet { store.set(enabled, forKey: Key.enabled) }
    }

    /// Seconds the hook helper waits for an answer before the CLI's own
    /// terminal prompt takes over. Clamped to `timeoutRange` when used.
    var responseTimeout: Double {
        didSet { store.set(responseTimeout, forKey: Key.responseTimeout) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        enabled = store.bool(Key.enabled, default: false)
        responseTimeout = store.double(Key.responseTimeout, default: 300)
        self.store = store
    }

    /// `responseTimeout` inside `timeoutRange`.
    var clampedResponseTimeout: Double {
        min(max(responseTimeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }
}
