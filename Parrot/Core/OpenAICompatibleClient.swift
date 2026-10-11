import Foundation

/// Chat-completions client for OpenAI and any OpenAI-compatible server
/// (Groq, DeepSeek, Ollama, LM Studio, llama.cpp, vLLM).
///
/// Sends POST {baseURL}/chat/completions with an optional Bearer token.
/// Local servers such as Ollama need no key.
struct OpenAICompatibleClient: RefinementClient {

    /// Base URL including the version path, e.g. "https://api.openai.com/v1"
    /// or "http://localhost:11434/v1".
    let baseURL: String
    /// Optional Bearer token. Nil for keyless local servers.
    let apiKey: String?
    var timeoutInterval: TimeInterval = 30
    /// How requests are sent; tests pass canned replies.
    var transport: any HTTPTransport = URLSessionTransport()

    func refine(_ text: String, system: String, model: String) async throws -> String {
        let request = try makeRequest(text, system: system, model: model)
        let (data, response) = try await transport.send(request)
        return try ChatCompletionResponse.content(
            from: data, statusCode: response.statusCode, errorMessage: Self.decodeErrorMessage
        )
    }

    /// The request `refine` sends.
    func makeRequest(_ text: String, system: String, model: String) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/chat/completions"
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw RefinementError.invalidEndpoint(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeoutInterval

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: text),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Decodes an OpenAI-style error body: {"error": {"message": ...}}.
    /// Ollama's native endpoints use a flat {"error": "..."} string instead,
    /// so both shapes are handled.
    static func decodeErrorMessage(from data: Data) -> String {
        if let wrapped = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return wrapped.error.message
        }
        if let flat = try? JSONDecoder().decode(FlatErrorEnvelope.self, from: data) {
            return flat.error
        }
        return String(data: data, encoding: .utf8) ?? "<unreadable>"
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let message: String
        }
    }

    private struct FlatErrorEnvelope: Decodable {
        let error: String
    }
}

// MARK: - Chat Completion Wire Types

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: MessageContent
        /// "stop", or "length" when the reply ran out of room.
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct MessageContent: Decodable {
        let content: String?
    }

    /// The reply text from a chat-completions response. Throws the decoded
    /// provider error on HTTP failure, `truncated` when the reply was cut
    /// short, and `emptyResponse` when there is no text.
    static func content(from data: Data, statusCode: Int, errorMessage: (Data) -> String) throws -> String {
        guard (200...299).contains(statusCode) else {
            throw RefinementError.providerError(statusCode: statusCode, message: errorMessage(data))
        }
        guard let completion = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            throw RefinementError.invalidResponse
        }
        guard let choice = completion.choices.first else { throw RefinementError.emptyResponse }
        if choice.finishReason == "length" { throw RefinementError.truncated }
        guard let content = choice.message.content, !content.isEmpty else {
            throw RefinementError.emptyResponse
        }
        return content
    }
}

// MARK: - Ollama Model Listing

/// Lists models installed on a local Ollama server via its native /api/tags
/// endpoint. The base URL is the OpenAI-compatible one (".../v1"); the /v1
/// suffix is stripped to reach the native API root.
enum OllamaAPI {

    static func listModels(baseURL: String) async throws -> [String] {
        var root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.hasSuffix("/v1") {
            root = String(root.dropLast(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let urlString = "\(root)/api/tags"
        guard let url = URL(string: urlString) else {
            throw RefinementError.invalidEndpoint(urlString)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RefinementError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw RefinementError.providerError(
                statusCode: httpResponse.statusCode,
                message: OpenAICompatibleClient.decodeErrorMessage(from: data)
            )
        }

        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tags.models.map(\.name)
    }

    private struct TagsResponse: Decodable {
        let models: [ModelEntry]
        struct ModelEntry: Decodable {
            let name: String
        }
    }
}
