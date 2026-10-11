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
        static let claudeStopHook = "parrot.agent.claudeStopHook"
        static let codexStopHook = "parrot.agent.codexStopHook"
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

    /// Reply to Claude Code when its turn ends. While Parrot waits for the
    /// reply the CLI waits too, so this is a choice per CLI. On by default.
    var claudeStopHook: Bool {
        didSet { store.set(claudeStopHook, forKey: Key.claudeStopHook) }
    }

    /// Reply to Codex when its turn ends. Off by default (opt in).
    var codexStopHook: Bool {
        didSet { store.set(codexStopHook, forKey: Key.codexStopHook) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        enabled = store.bool(Key.enabled, default: false)
        responseTimeout = store.double(Key.responseTimeout, default: 300)
        claudeStopHook = store.bool(Key.claudeStopHook, default: true)
        codexStopHook = store.bool(Key.codexStopHook, default: false)
        self.store = store
    }

    func stopHookEnabled(for agent: HookAgent) -> Bool {
        switch agent {
        case .claude: return claudeStopHook
        case .codex: return codexStopHook
        }
    }

    func setStopHook(_ on: Bool, for agent: HookAgent) {
        switch agent {
        case .claude: claudeStopHook = on
        case .codex: codexStopHook = on
        }
    }

    /// The CLIs whose Stop event Parrot answers.
    var stopHookAgents: [HookAgent] {
        HookAgent.allCases.filter(stopHookEnabled(for:))
    }

    /// `responseTimeout` inside `timeoutRange`.
    var clampedResponseTimeout: Double {
        min(max(responseTimeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    }
}
