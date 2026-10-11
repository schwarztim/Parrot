import Foundation

// MARK: - CustomLanguageModel

/// A model the user added with their own key ("Bring your own key"). Stored
/// as JSON in `parrot.llm.customModels`; never holds a secret. Its key is the
/// provider's key in `ProviderCredentials` (one key per provider, so two
/// OpenAI-compatible endpoints that need different keys are not supported).
struct CustomLanguageModel: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var provider: RefinementProvider
    /// The provider's model id (or the Azure deployment name).
    var modelID: String
    /// API root. Empty uses the provider's default (or its settings field).
    var baseURL: String

    init(id: String = UUID().uuidString.lowercased(), name: String, provider: RefinementProvider, modelID: String, baseURL: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.modelID = modelID
        self.baseURL = baseURL
    }

    /// The id modes store to use this model.
    var languageModelID: String { LanguageModelCatalog.customPrefix + id }
}

// MARK: - LanguageModelTarget

/// A resolved language model: the client to call and the model to ask for.
struct LanguageModelTarget {
    let provider: RefinementProvider
    let model: String
    let client: RefinementClient
    /// Runs on this Mac (or the local network): full context, warm-up allowed.
    let isLocal: Bool
}

/// Where a language model lives: provider, model, API root and key. The key
/// stays in memory only; never log or display this value.
struct LanguageModelEndpoint {
    let provider: RefinementProvider
    let model: String
    /// API root (the Azure resource endpoint for Azure).
    let baseURL: String
    let apiKey: String
    let isLocal: Bool
}

/// One row in a language model picker.
struct LanguageModelChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

// MARK: - LanguageModelCatalog

/// Turns a mode's `languageModelID` into a client. [LLM]
///
/// Ids:
/// - "" uses the global provider and model from Language Models settings.
/// - "<provider>/<model>" uses that provider's key and endpoint settings with
///   the given model ("groq/llama-3.3-70b-versatile"; the model part may
///   itself contain slashes).
/// - "custom/<id>" uses a model from `RefinementSettings.customModels`.
///
/// An id that matches none of these throws `modelNotFound`; a provider that
/// lacks its key or endpoint throws `notConfigured`. Both make the dictation
/// fall back to the raw transcript.
enum LanguageModelCatalog {

    static let customPrefix = "custom/"

    static func resolve(
        _ id: String,
        settings: AppSettings,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws -> LanguageModelTarget {
        let endpoint = try endpoint(id, settings: settings)
        return LanguageModelTarget(
            provider: endpoint.provider,
            model: endpoint.model,
            client: makeClient(for: endpoint, settings: settings, transport: transport),
            isLocal: endpoint.isLocal
        )
    }

    /// Provider, model, API root and key for `id`, without building a client.
    static func endpoint(_ id: String, settings: AppSettings) throws -> LanguageModelEndpoint {
        let refinement = settings.refinement
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            let provider = refinement.refinementProvider
            return try endpoint(provider: provider, model: configuredModel(for: provider, settings: settings),
                                baseURL: "", settings: settings)
        }
        if trimmed.hasPrefix(customPrefix) {
            let customID = String(trimmed.dropFirst(customPrefix.count))
            guard let custom = refinement.customModels.first(where: { $0.id == customID }) else {
                throw RefinementError.modelNotFound(trimmed)
            }
            return try endpoint(provider: custom.provider, model: custom.modelID, baseURL: custom.baseURL, settings: settings)
        }
        guard let slash = trimmed.firstIndex(of: "/"),
              let provider = RefinementProvider(rawValue: String(trimmed[..<slash]))
        else { throw RefinementError.modelNotFound(trimmed) }
        let model = String(trimmed[trimmed.index(after: slash)...])
        guard !model.isEmpty else { throw RefinementError.modelNotFound(trimmed) }
        return try endpoint(provider: provider, model: model, baseURL: "", settings: settings)
    }

    /// Whether `id` runs locally, without resolving a client. Unknown or
    /// unconfigured ids count as cloud, so redaction errs on the safe side.
    static func isLocal(_ id: String, settings: AppSettings) -> Bool {
        (try? resolve(id, settings: settings))?.isLocal ?? false
    }

    /// The model the global settings choose for `provider`.
    static func configuredModel(for provider: RefinementProvider, settings: AppSettings) -> String {
        let refinement = settings.refinement
        switch provider {
        case .localServer: return refinement.localServerModel
        case .openAI: return refinement.openAIModel
        case .azureOpenAI: return refinement.azureOpenAIDeployment
        case .anthropic: return refinement.anthropicModel
        case .groq: return refinement.groqModel
        case .gemini: return refinement.geminiModel
        case .deepseek: return refinement.deepseekModel
        case .openAICompatible: return refinement.compatibleModel
        }
    }

    /// Whether `provider` has its key and endpoint.
    static func isConfigured(_ provider: RefinementProvider, settings: AppSettings) -> Bool {
        (try? endpoint(provider: provider, model: configuredModel(for: provider, settings: settings),
                       baseURL: "", settings: settings)) != nil
    }

    /// Picker rows: the global default, each configured provider's model and
    /// every custom model. `including` keeps a mode's current id listed even
    /// when it no longer resolves.
    static func choices(settings: AppSettings, including current: String? = nil) -> [LanguageModelChoice] {
        let global = settings.refinement.refinementProvider
        var rows = [LanguageModelChoice(
            id: "",
            title: "Default (\(global.shortName): \(configuredModel(for: global, settings: settings)))"
        )]
        for provider in RefinementProvider.allCases where isConfigured(provider, settings: settings) {
            let model = configuredModel(for: provider, settings: settings)
            rows.append(LanguageModelChoice(id: "\(provider.rawValue)/\(model)", title: "\(provider.shortName): \(model)"))
        }
        for custom in settings.refinement.customModels {
            rows.append(LanguageModelChoice(id: custom.languageModelID, title: "\(custom.name) (\(custom.provider.shortName))"))
        }
        if let current, !current.isEmpty, !rows.contains(where: { $0.id == current }) {
            rows.append(LanguageModelChoice(id: current, title: "Missing: \(current)"))
        }
        return rows
    }

    /// A short label for a mode's model id.
    static func displayName(for id: String, settings: AppSettings) -> String {
        choices(settings: settings, including: id).first { $0.id == id }?.title ?? id
    }

    // MARK: - Private

    private static func endpoint(
        provider: RefinementProvider,
        model: String,
        baseURL override: String,
        settings: AppSettings
    ) throws -> LanguageModelEndpoint {
        let refinement = settings.refinement
        let key = settings.credentials.key(for: provider.credential)
        let customBase = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw RefinementError.notConfigured }
        if provider.requiresKey, key.isEmpty { throw RefinementError.notConfigured }

        let base: String
        switch provider {
        case .localServer:
            base = customBase.isEmpty ? refinement.localServerBaseURL : customBase
        case .openAICompatible:
            base = customBase.isEmpty ? refinement.compatibleBaseURL : customBase
        case .azureOpenAI:
            base = customBase.isEmpty ? refinement.azureOpenAIEndpoint : customBase
        case .openAI, .groq, .deepseek, .anthropic, .gemini:
            base = customBase.isEmpty ? (provider.defaultBaseURL ?? "") : customBase
        }
        guard !base.isEmpty else { throw RefinementError.notConfigured }

        let local = provider == .localServer || (provider == .openAICompatible && isLoopback(base))
        return LanguageModelEndpoint(provider: provider, model: model, baseURL: base, apiKey: key, isLocal: local)
    }

    /// The client for an endpoint.
    static func makeClient(
        for endpoint: LanguageModelEndpoint,
        settings: AppSettings,
        transport: any HTTPTransport
    ) -> RefinementClient {
        let key = endpoint.apiKey
        switch endpoint.provider {
        case .localServer, .openAICompatible, .openAI, .groq, .deepseek:
            return OpenAICompatibleClient(baseURL: endpoint.baseURL, apiKey: key.isEmpty ? nil : key, transport: transport)
        case .azureOpenAI:
            return AzureOpenAIClient(
                endpoint: endpoint.baseURL, apiKey: key,
                apiVersion: settings.refinement.azureOpenAIAPIVersion, transport: transport
            )
        case .anthropic:
            return AnthropicClient(apiKey: key, baseURL: endpoint.baseURL, transport: transport)
        case .gemini:
            return GeminiClient(apiKey: key, baseURL: endpoint.baseURL, transport: transport)
        }
    }

    /// True for localhost, 127.x, ::1 and `.local` hosts.
    static func isLoopback(_ baseURL: String) -> Bool {
        guard let host = URLComponents(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host.hasPrefix("127.") || host == "::1" || host == "[::1]" || host.hasSuffix(".local")
    }
}
