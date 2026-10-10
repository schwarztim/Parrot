import Foundation
import Observation

// MARK: - ProviderID

/// A provider whose API key Parrot keeps. The raw value is its Keychain
/// service, which never changes: installed users already have these items.
enum ProviderID: String, CaseIterable, Sendable {
    case openAI = "com.parrot.openai"
    case azureOpenAI = "com.parrot.azure-openai"
    case anthropic = "com.parrot.anthropic"
    case localServer = "com.parrot.local-server"

    // Predeclared for upcoming providers; nothing reads these yet.
    case groq = "com.parrot.groq"
    case gemini = "com.parrot.gemini"
    case deepseek = "com.parrot.deepseek"
    case deepgram = "com.parrot.deepgram"
    case elevenlabs = "com.parrot.elevenlabs"

    var keychainService: String { rawValue }
}

// MARK: - ProviderCredentials

/// API keys for every provider, one Keychain item each, never logged. [LLM]
///
/// Keys load once in `init`. A key that cannot be read (a locked keychain
/// over ssh, a denied prompt) shows as empty and is left untouched: loading
/// never writes or deletes. Only an explicit `setKey(_:for:)` or
/// `removeKey(for:)` changes the store.
@Observable
final class ProviderCredentials {

    private var keys: [ProviderID: String]

    /// Providers whose saved key could not be read at launch. Their keys
    /// read as empty until the user sets them again.
    private(set) var unreadable: Set<ProviderID>

    private let secrets: SecretStore

    /// - Parameter secrets: Where keys live. Nil uses an empty in-memory
    ///   store, so a caller that forgets it can never reach the Keychain.
    init(store: SettingsStore, secrets: SecretStore? = nil) {
        let secrets = secrets ?? InMemorySecretStore()
        var keys: [ProviderID: String] = [:]
        var unreadable: Set<ProviderID> = []
        for id in ProviderID.allCases {
            do {
                if let value = try secrets.read(service: id.keychainService) {
                    keys[id] = value
                }
            } catch {
                unreadable.insert(id)
            }
        }
        self.keys = keys
        self.unreadable = unreadable
        self.secrets = secrets
    }

    /// The saved key, or "" when none is saved or it could not be read.
    func key(for id: ProviderID) -> String {
        keys[id] ?? ""
    }

    /// Saves a key the user entered. An empty value deletes the saved key;
    /// this and `removeKey(for:)` are the only paths that delete.
    func setKey(_ value: String, for id: ProviderID) {
        keys[id] = value.isEmpty ? nil : value
        unreadable.remove(id)
        if value.isEmpty {
            try? secrets.delete(service: id.keychainService)
        } else {
            try? secrets.write(value, service: id.keychainService)
        }
    }

    /// Deletes the saved key (a "Remove key" action).
    func removeKey(for id: ProviderID) {
        setKey("", for: id)
    }

    // MARK: - Current Providers

    // Bindable forms of the four keys the settings fields edit today.

    var openAIKey: String {
        get { key(for: .openAI) }
        set { update(newValue, for: .openAI) }
    }

    var azureOpenAIKey: String {
        get { key(for: .azureOpenAI) }
        set { update(newValue, for: .azureOpenAI) }
    }

    var anthropicKey: String {
        get { key(for: .anthropic) }
        set { update(newValue, for: .anthropic) }
    }

    /// Optional Bearer token for local servers that require one.
    var localServerKey: String {
        get { key(for: .localServer) }
        set { update(newValue, for: .localServer) }
    }

    /// A field edit. Skips unchanged values, so a field that only redraws
    /// never writes or deletes.
    private func update(_ value: String, for id: ProviderID) {
        guard value != key(for: id) else { return }
        setKey(value, for: id)
    }
}
