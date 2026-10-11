import Foundation

// MARK: - RefinementProvider

/// A language model provider. Raw values are stored in settings and in
/// language model ids; they never change.
enum RefinementProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case localServer
    case openAI
    case azureOpenAI
    case anthropic
    case groq
    case gemini
    case deepseek
    /// Any other server that speaks the OpenAI chat-completions format.
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localServer: return "Local (Ollama / OpenAI-compatible)"
        case .openAI: return "OpenAI"
        case .azureOpenAI: return "Azure OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .groq: return "Groq"
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        }
    }

    /// Short name for pickers ("Groq: llama-3.3-70b-versatile").
    var shortName: String {
        switch self {
        case .localServer: return "Local"
        case .openAI: return "OpenAI"
        case .azureOpenAI: return "Azure"
        case .anthropic: return "Anthropic"
        case .groq: return "Groq"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .openAICompatible: return "Compatible"
        }
    }

    /// Where this provider's API key lives.
    var credential: ProviderID {
        switch self {
        case .localServer: return .localServer
        case .openAI: return .openAI
        case .azureOpenAI: return .azureOpenAI
        case .anthropic: return .anthropic
        case .groq: return .groq
        case .gemini: return .gemini
        case .deepseek: return .deepseek
        case .openAICompatible: return .openAICompatible
        }
    }

    /// Whether requests fail without a key. Local and generic endpoints may
    /// be keyless.
    var requiresKey: Bool {
        self != .localServer && self != .openAICompatible
    }

    /// The fixed API root for hosted providers; nil where the user enters it.
    var defaultBaseURL: String? {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .anthropic: return AnthropicClient.defaultBaseURL
        case .gemini: return GeminiClient.defaultBaseURL
        case .localServer, .azureOpenAI, .openAICompatible: return nil
        }
    }
}

// MARK: - RefinementClient

/// A client that sends a raw transcript to an LLM and returns the refined text.
protocol RefinementClient {
    /// Refines the given text using the provider's chat/messages API.
    ///
    /// - Parameters:
    ///   - text: Raw transcript to refine.
    ///   - system: System prompt describing the refinement task.
    ///   - model: Model identifier (or deployment name, provider-dependent).
    /// - Returns: The refined text.
    func refine(_ text: String, system: String, model: String) async throws -> String
}

// MARK: - RefinementRequest

/// One refinement call: the prompt rendered at recording start with the
/// transcript filled in, and the language model to use.
struct RefinementRequest: Equatable, Sendable {
    var system: String
    var user: String
    /// The mode's language model id; "" uses the global provider.
    var languageModelID: String
}

// MARK: - RefinementGate

/// Whether a dictation goes through the language model.
enum RefinementGate {
    /// Voice modes never do (unless forced). Otherwise refinement runs when
    /// it is on globally, when this dictation forces it, or when the mode
    /// names a language model of its own (choosing one opts that mode in).
    static func shouldRefine(mode: Mode?, settings: AppSettings, forced: Bool) -> Bool {
        if forced { return true }
        if let mode, !ModePresets.usesLanguageModel(mode.type) { return false }
        if settings.refinement.refinementEnabled { return true }
        return !(mode?.languageModelID ?? "").isEmpty
    }
}

// MARK: - RefinementService

/// Picks the configured refinement client from settings and runs refinement.
enum RefinementService {

    /// Default per-mode directive. A mode's refinement prompt replaces this
    /// directive; the surrounding scaffold below is always applied.
    static let defaultDirective = """
        Correct speech-to-text errors: wrong homophones, misrecognized words, \
        run-on sentences, missing punctuation, and capitalization. Remove filler \
        words (um, uh, you know) and false starts. Break the text into sentences \
        and paragraphs where natural. Keep my wording.
        """

    /// The system prompt for a bare directive and an optional destination,
    /// through the same renderer dictations use (Custom type, no examples).
    static func systemPrompt(directive: String?, context: DictationContext? = nil) -> String {
        let mode = Mode(name: "", type: .custom, refinementPrompt: directive)
        return PromptRenderer.render(mode: mode, context: .legacy(context)).system
    }

    /// Builds the client and model for the provider selected in settings.
    /// Returns nil when the selected provider is missing required configuration.
    static func makeClient(from settings: AppSettings) -> (client: RefinementClient, model: String)? {
        guard let target = try? LanguageModelCatalog.resolve("", settings: settings) else { return nil }
        return (target.client, target.model)
    }

    /// Whether the provider selected in settings has everything it needs.
    static func isConfigured(_ settings: AppSettings) -> Bool {
        makeClient(from: settings) != nil
    }

    /// Warms a local refinement model (Ollama, LM Studio, etc.) with a tiny
    /// throwaway request so it is loaded and ready by the time the user stops
    /// speaking. Only fires for local providers, to avoid billing cloud APIs.
    static func warmUpIfLocal(settings: AppSettings) {
        guard settings.refinement.refinementEnabled else { return }
        warmUp(languageModelID: "", settings: settings)
    }

    /// Warms the given model when it runs locally; never touches a cloud API.
    static func warmUp(languageModelID: String, settings: AppSettings) {
        guard let target = try? LanguageModelCatalog.resolve(languageModelID, settings: settings),
              target.isLocal
        else { return }
        Task.detached {
            _ = try? await target.client.refine("warm", system: "Reply with: ok", model: target.model)
        }
    }

    /// Refines the transcript with the configured provider.
    ///
    /// - Parameters:
    ///   - text: Raw transcript.
    ///   - modePrompt: Optional per-mode directive override; falls back to
    ///     ``defaultDirective`` when nil or empty.
    ///   - context: Optional destination context. Redacted to metadata-only for
    ///     cloud providers when ``RefinementSettings/contextLocalOnly`` is on.
    ///   - settings: App settings supplying provider choice and credentials.
    /// - Throws: ``RefinementError/notConfigured`` or a provider error.
    static func refine(
        _ text: String,
        modePrompt: String?,
        context: DictationContext? = nil,
        settings: AppSettings
    ) async throws -> String {
        let target = try LanguageModelCatalog.resolve("", settings: settings)

        // Decide what context, if any, reaches the provider.
        var effectiveContext: DictationContext?
        let refinement = settings.refinement
        if refinement.destinationAwareRefinement, let context, !context.isSecureField {
            effectiveContext = (!target.isLocal && refinement.contextLocalOnly) ? context.redactedForCloud : context
        }

        let system = systemPrompt(directive: modePrompt, context: effectiveContext)
        return try await complete(target: target, system: system, user: text)
    }

    /// Sends a rendered request to the mode's language model and cleans the
    /// reply (reasoning blocks and wrappers removed).
    static func refine(
        _ request: RefinementRequest,
        settings: AppSettings,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> String {
        let target = try LanguageModelCatalog.resolve(request.languageModelID, settings: settings, transport: transport)
        return try await complete(target: target, system: request.system, user: request.user)
    }

    private static func complete(target: LanguageModelTarget, system: String, user: String) async throws -> String {
        let reply = try await target.client.refine(user, system: system, model: target.model)
        try Task.checkCancellation()
        let cleaned = OutputCleaner.clean(reply)
        guard !cleaned.isEmpty else { throw RefinementError.emptyResponse }
        return cleaned
    }
}

// MARK: - Refiner

/// The refinement calls a dictation makes, behind a protocol so stages can
/// be handed a fake. `ConfiguredRefiner` forwards to `RefinementService`.
protocol Refiner {
    func refine(
        _ text: String,
        modePrompt: String?,
        context: DictationContext?,
        settings: AppSettings
    ) async throws -> String

    func warmUpIfLocal(settings: AppSettings)

    /// Refines a prompt rendered for the dictation's mode.
    func refine(_ request: RefinementRequest, settings: AppSettings) async throws -> String

    /// Warms the mode's model when it is local.
    func warmUp(languageModelID: String, settings: AppSettings)
}

extension Refiner {
    /// For refiners written before rendered prompts: sends the transcript
    /// with the default directive.
    func refine(_ request: RefinementRequest, settings: AppSettings) async throws -> String {
        try await refine(request.user, modePrompt: nil, context: nil, settings: settings)
    }

    func warmUp(languageModelID: String, settings: AppSettings) {
        warmUpIfLocal(settings: settings)
    }
}

/// Refines with the provider configured in settings.
struct ConfiguredRefiner: Refiner {
    /// How requests are sent; tests pass canned replies.
    var transport: any HTTPTransport = URLSessionTransport()

    func refine(
        _ text: String,
        modePrompt: String?,
        context: DictationContext?,
        settings: AppSettings
    ) async throws -> String {
        try await RefinementService.refine(text, modePrompt: modePrompt, context: context, settings: settings)
    }

    func warmUpIfLocal(settings: AppSettings) {
        RefinementService.warmUpIfLocal(settings: settings)
    }

    func refine(_ request: RefinementRequest, settings: AppSettings) async throws -> String {
        try await RefinementService.refine(request, settings: settings, transport: transport)
    }

    func warmUp(languageModelID: String, settings: AppSettings) {
        RefinementService.warmUp(languageModelID: languageModelID, settings: settings)
    }
}

// MARK: - Errors

enum RefinementError: LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    case invalidResponse
    /// HTTP failure with the provider's decoded error message.
    case providerError(statusCode: Int, message: String)
    case emptyResponse
    /// The mode names a language model Parrot does not know.
    case modelNotFound(String)
    /// The reply stopped at the length limit (the model ran out of room).
    case truncated

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Refinement is not configured. Choose a provider and enter its details in Language Models."
        case .invalidEndpoint(let url):
            return "Invalid API endpoint URL: \(url)"
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .providerError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .emptyResponse:
            return "The API returned an empty response with no content."
        case .modelNotFound(let id):
            return "Language model \"\(id)\" was not found."
        case .truncated:
            return "The language model ran out of room and cut its answer short."
        }
    }
}
