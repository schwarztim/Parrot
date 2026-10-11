import Foundation
import Observation

/// LLM refinement settings: provider choice, models and endpoints. [LLM]
///
/// API keys live in `ProviderCredentials`, not here.
@Observable
final class RefinementSettings {

    private enum Key {
        // Legacy enhance-mode keys, migrated to the Azure OpenAI refinement fields.
        static let enhanceEndpoint = "parrot.enhanceEndpoint"
        static let enhanceModel = "parrot.enhanceModel"
        static let refinementEnabled = "parrot.refinementEnabled"
        static let refinementProvider = "parrot.refinementProvider"
        static let localServerBaseURL = "parrot.localServerBaseURL"
        static let localServerModel = "parrot.localServerModel"
        static let openAIModel = "parrot.openAIModel"
        static let azureOpenAIEndpoint = "parrot.azureOpenAIEndpoint"
        static let azureOpenAIDeployment = "parrot.azureOpenAIDeployment"
        static let azureOpenAIAPIVersion = "parrot.azureOpenAIAPIVersion"
        static let anthropicModel = "parrot.anthropicModel"
        static let destinationAwareRefinement = "parrot.destinationAwareRefinement"
        static let contextLocalOnly = "parrot.contextLocalOnly"
        static let groqModel = "parrot.llm.groqModel"
        static let geminiModel = "parrot.llm.geminiModel"
        static let deepseekModel = "parrot.llm.deepseekModel"
        static let compatibleBaseURL = "parrot.llm.compatibleBaseURL"
        static let compatibleModel = "parrot.llm.compatibleModel"
        static let customModels = "parrot.llm.customModels"
        static let includeContactCard = "parrot.llm.includeContactCard"
    }

    /// Legacy enhance-mode Keychain service, migrated to the Azure item.
    private static let legacyKeychainService = "com.parrot.enhance"

    /// When true, transcripts are refined by the selected LLM provider before
    /// pasting. When false (or the provider is unconfigured), the raw
    /// transcript is pasted unchanged, so the app works fully offline.
    var refinementEnabled: Bool {
        didSet { store.set(refinementEnabled, forKey: Key.refinementEnabled) }
    }

    var refinementProvider: RefinementProvider {
        didSet { store.set(refinementProvider, forKey: Key.refinementProvider) }
    }

    /// OpenAI-compatible base URL for local servers (Ollama, LM Studio,
    /// llama.cpp, vLLM), including the version path.
    var localServerBaseURL: String {
        didSet { store.set(localServerBaseURL, forKey: Key.localServerBaseURL) }
    }

    var localServerModel: String {
        didSet { store.set(localServerModel, forKey: Key.localServerModel) }
    }

    var openAIModel: String {
        didSet { store.set(openAIModel, forKey: Key.openAIModel) }
    }

    /// Azure resource endpoint, e.g. "https://my-resource.openai.azure.com".
    var azureOpenAIEndpoint: String {
        didSet { store.set(azureOpenAIEndpoint, forKey: Key.azureOpenAIEndpoint) }
    }

    /// Azure chat-model deployment name.
    var azureOpenAIDeployment: String {
        didSet { store.set(azureOpenAIDeployment, forKey: Key.azureOpenAIDeployment) }
    }

    var azureOpenAIAPIVersion: String {
        didSet { store.set(azureOpenAIAPIVersion, forKey: Key.azureOpenAIAPIVersion) }
    }

    var anthropicModel: String {
        didSet { store.set(anthropicModel, forKey: Key.anthropicModel) }
    }

    /// When on, refinement is told which app and field the text is going into,
    /// so it matches the destination's tone and format. Reads only local
    /// Accessibility data.
    var destinationAwareRefinement: Bool {
        didSet { store.set(destinationAwareRefinement, forKey: Key.destinationAwareRefinement) }
    }

    /// When on, field text content is never sent to cloud refinement providers
    /// (only app and field metadata are). Local providers still see full context.
    var contextLocalOnly: Bool {
        didSet { store.set(contextLocalOnly, forKey: Key.contextLocalOnly) }
    }

    var groqModel: String {
        didSet { store.set(groqModel, forKey: Key.groqModel) }
    }

    var geminiModel: String {
        didSet { store.set(geminiModel, forKey: Key.geminiModel) }
    }

    var deepseekModel: String {
        didSet { store.set(deepseekModel, forKey: Key.deepseekModel) }
    }

    /// API root of the generic OpenAI-compatible endpoint, with the version
    /// path. Loopback addresses count as local (no redaction).
    var compatibleBaseURL: String {
        didSet { store.set(compatibleBaseURL, forKey: Key.compatibleBaseURL) }
    }

    var compatibleModel: String {
        didSet { store.set(compatibleModel, forKey: Key.compatibleModel) }
    }

    /// Models added with "Bring your own key". No secrets: keys stay in
    /// `ProviderCredentials`.
    var customModels: [CustomLanguageModel] {
        didSet { store.setEncoded(customModels, forKey: Key.customModels) }
    }

    /// Share the Contacts "Me" card (name, email, phone) in modes with
    /// application context on.
    var includeContactCard: Bool {
        didSet { store.set(includeContactCard, forKey: Key.includeContactCard) }
    }

    private let store: SettingsStore

    /// Runs the legacy enhance migration, then loads. AppSettings builds this
    /// area before `ProviderCredentials`, so the migrated Azure key is there
    /// when the keys load.
    init(store: SettingsStore, secrets: SecretStore? = nil) {
        Self.migrateLegacyEnhanceSettings(store: store, secrets: secrets)

        refinementEnabled = store.bool(Key.refinementEnabled, default: false)
        refinementProvider = store.value(Key.refinementProvider, default: .localServer)
        localServerBaseURL = store.string(Key.localServerBaseURL, default: "http://localhost:11434/v1")
        localServerModel = store.string(Key.localServerModel, default: "")
        openAIModel = store.string(Key.openAIModel, default: "gpt-4o-mini")
        azureOpenAIEndpoint = store.string(Key.azureOpenAIEndpoint, default: "")
        azureOpenAIDeployment = store.string(Key.azureOpenAIDeployment, default: "")
        azureOpenAIAPIVersion = store.string(Key.azureOpenAIAPIVersion, default: "2024-10-21")
        anthropicModel = store.string(Key.anthropicModel, default: "claude-haiku-4-5")
        destinationAwareRefinement = store.bool(Key.destinationAwareRefinement, default: true)
        contextLocalOnly = store.bool(Key.contextLocalOnly, default: true)
        groqModel = store.string(Key.groqModel, default: "llama-3.3-70b-versatile")
        geminiModel = store.string(Key.geminiModel, default: "gemini-2.5-flash")
        deepseekModel = store.string(Key.deepseekModel, default: "deepseek-chat")
        compatibleBaseURL = store.string(Key.compatibleBaseURL, default: "http://localhost:1234/v1")
        compatibleModel = store.string(Key.compatibleModel, default: "")
        customModels = store.decoded([CustomLanguageModel].self, forKey: Key.customModels) ?? []
        includeContactCard = store.bool(Key.includeContactCard, default: false)
        self.store = store
    }

    /// One-time migration of the old enhance-mode configuration (which was
    /// Azure OpenAI) into the Azure refinement keys and Keychain service.
    ///
    /// Writes the store directly, before loading. If the old API key cannot
    /// be read (a locked keychain) or saved to its new item, nothing changes,
    /// so the migration runs again next launch instead of losing the key.
    private static func migrateLegacyEnhanceSettings(store: SettingsStore, secrets: SecretStore?) {
        let legacyEndpoint = store.string(Key.enhanceEndpoint, default: "")
        guard store.string(Key.azureOpenAIEndpoint, default: "").isEmpty, !legacyEndpoint.isEmpty else { return }

        if let secrets {
            do {
                if let legacyKey = try secrets.read(service: legacyKeychainService), !legacyKey.isEmpty {
                    try secrets.write(legacyKey, service: ProviderID.azureOpenAI.keychainService)
                    try? secrets.delete(service: legacyKeychainService)
                }
            } catch {
                return
            }
        }

        // Old UI suggested endpoints like ".../openai/v1"; the Azure client
        // appends its own path, so strip anything from "/openai" on.
        var endpoint = legacyEndpoint
        if let range = endpoint.range(of: "/openai") {
            endpoint = String(endpoint[..<range.lowerBound])
        }
        store.set(endpoint, forKey: Key.azureOpenAIEndpoint)
        store.set(store.string(Key.enhanceModel, default: ""), forKey: Key.azureOpenAIDeployment)
        store.set(RefinementProvider.azureOpenAI, forKey: Key.refinementProvider)

        store.remove(Key.enhanceEndpoint)
        store.remove(Key.enhanceModel)
    }
}
