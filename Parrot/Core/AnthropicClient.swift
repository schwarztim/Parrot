import Foundation

/// Messages API client for Anthropic Claude.
///
/// Sends POST https://api.anthropic.com/v1/messages with x-api-key and
/// anthropic-version headers. The system prompt is a top-level field (not a
/// message role) and the response content is an array of typed blocks; the
/// refined text is the first block with type "text".
struct AnthropicClient: RefinementClient {

    let apiKey: String
    var timeoutInterval: TimeInterval = 30

    private static let endpoint = "https://api.anthropic.com/v1/messages"
    private static let apiVersion = "2023-06-01"
    /// Generous ceiling; refinement output is roughly the transcript length.
    private static let maxTokens = 4096

    func refine(_ text: String, system: String, model: String) async throws -> String {
        guard let url = URL(string: Self.endpoint) else {
            throw RefinementError.invalidEndpoint(Self.endpoint)
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RefinementError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw RefinementError.providerError(
                statusCode: httpResponse.statusCode,
                message: Self.decodeErrorMessage(from: data)
            )
        }

        let message = try JSONDecoder().decode(MessagesResponse.self, from: data)
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
