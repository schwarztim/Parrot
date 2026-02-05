import Foundation

/// Sends raw transcription text to Azure OpenAI for polishing and professional rewriting.
///
/// Uses the standard OpenAI chat completions API format over URLSession.
/// Configuration properties (endpoint, API key, model) are observable and can
/// be changed at runtime.
@Observable
final class TextEnhancer {

    // MARK: - Configuration

    var endpoint: String = ""
    var apiKey: String = ""
    var model: String = ""

    /// Whether the enhancer has valid configuration to make requests.
    var isConfigured: Bool {
        !endpoint.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    /// The system prompt sent with every enhancement request.
    var systemPrompt: String = """
        You are a writing assistant. Take the user's spoken transcription and rewrite \
        it to be clear, professional, and well-structured. Fix grammar, remove filler \
        words, and improve clarity while preserving the original meaning and intent. \
        Return ONLY the improved text with no explanation.
        """

    /// Request timeout in seconds.
    var timeoutInterval: TimeInterval = 30

    // MARK: - Enhance

    /// Loads configuration from AppSettings (endpoint, model from UserDefaults;
    /// API key from Keychain).
    func configure(from settings: AppSettings) {
        endpoint = settings.enhanceEndpoint
        model = settings.enhanceModel
        apiKey = settings.enhanceApiKey
    }

    /// Sends the given transcription text to Azure OpenAI and returns the
    /// polished version.
    ///
    /// - Parameter text: Raw transcription text to enhance.
    /// - Returns: The enhanced, polished text.
    /// - Throws: ``TextEnhancerError`` if the request fails or returns an
    ///   unexpected response.
    func enhance(_ text: String) async throws -> String {
        guard isConfigured else {
            throw TextEnhancerError.notConfigured
        }
        let url = try buildURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutInterval

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TextEnhancerError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw TextEnhancerError.httpError(
                statusCode: httpResponse.statusCode,
                body: responseBody
            )
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let content = completion.choices.first?.message.content,
              !content.isEmpty
        else {
            throw TextEnhancerError.emptyResponse
        }

        return content
    }

    // MARK: - Private Helpers

    private func buildURL() throws -> URL {
        // Strip trailing slashes for consistent joining.
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/chat/completions"

        guard let url = URL(string: urlString) else {
            throw TextEnhancerError.invalidEndpoint(urlString)
        }
        return url
    }
}

// MARK: - Request / Response Models

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: MessageContent
    }

    struct MessageContent: Decodable {
        let content: String?
    }
}

// MARK: - Errors

enum TextEnhancerError: LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Enhance mode is not configured. Set endpoint, model, and API key in Configuration."
        case .invalidEndpoint(let url):
            return "Invalid API endpoint URL: \(url)"
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body)"
        case .emptyResponse:
            return "The API returned an empty response with no content."
        }
    }
}
