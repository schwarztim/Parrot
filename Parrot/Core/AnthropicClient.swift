import Foundation

/// Messages API client for Anthropic Claude.
///
/// Sends POST {baseURL}/messages with x-api-key and anthropic-version
/// headers. The system prompt is a top-level field (not a message role) and
/// the response content is an array of typed blocks; the refined text is
/// the first block with type "text".
struct AnthropicClient: RefinementClient {

    let apiKey: String
    var timeoutInterval: TimeInterval = 30
    /// API root including the version path.
    var baseURL: String = AnthropicClient.defaultBaseURL
    /// How requests are sent; tests pass canned replies.
    var transport: any HTTPTransport = URLSessionTransport()

    static let defaultBaseURL = "https://api.anthropic.com/v1"
    static let apiVersion = "2023-06-01"
    /// Generous ceiling; refinement output is roughly the transcript length.
    private static let maxTokens = 4096

    func refine(_ text: String, system: String, model: String) async throws -> String {
        let request = try makeRequest(text, system: system, model: model)
        let (data, response) = try await transport.send(request)
        return try Self.parse(data: data, statusCode: response.statusCode)
    }

    /// The request `refine` sends.
    func makeRequest(_ text: String, system: String, model: String) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/messages"
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw RefinementError.invalidEndpoint(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = timeoutInterval

        let body = MessagesRequest(
            model: model,
            maxTokens: Self.maxTokens,
            system: system,
            messages: [.init(role: "user", content: text)]
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// The reply text, or the provider error, `truncated` (stopped at the
    /// token limit) or `emptyResponse`.
    static func parse(data: Data, statusCode: Int) throws -> String {
        guard (200...299).contains(statusCode) else {
            throw RefinementError.providerError(statusCode: statusCode, message: decodeErrorMessage(from: data))
        }
        guard let message = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw RefinementError.invalidResponse
        }
        if message.stopReason == "max_tokens" { throw RefinementError.truncated }
        guard let textBlock = message.content.first(where: { $0.type == "text" }),
              let content = textBlock.text,
              !content.isEmpty
        else {
            throw RefinementError.emptyResponse
        }
        return content
    }

    /// Decodes an Anthropic error body:
    /// {"type": "error", "error": {"type": ..., "message": ...}}.
    static func decodeErrorMessage(from data: Data) -> String {
        if let wrapped = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return wrapped.error.message
        }
        return String(data: data, encoding: .utf8) ?? "<unreadable>"
    }

    // MARK: - Wire Types

    private struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let message: String
        }
    }
}
