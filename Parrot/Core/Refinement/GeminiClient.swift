import Foundation

/// Google Gemini client using the native generateContent API. [LLM]
///
/// Sends POST {baseURL}/models/{model}:generateContent with the key in the
/// "x-goog-api-key" header (never in the URL, so it stays out of logs). The
/// system prompt goes in `systemInstruction`; parts a thinking model marks
/// as thoughts are skipped.
struct GeminiClient: RefinementClient {

    let apiKey: String
    var baseURL: String = GeminiClient.defaultBaseURL
    var timeoutInterval: TimeInterval = 30
    /// How requests are sent; tests pass canned replies.
    var transport: any HTTPTransport = URLSessionTransport()

    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    func refine(_ text: String, system: String, model: String) async throws -> String {
        let request = try makeRequest(text, system: system, model: model)
        let (data, response) = try await transport.send(request)
        return try Self.parse(data: data, statusCode: response.statusCode)
    }

    /// The request `refine` sends.
    func makeRequest(_ text: String, system: String, model: String) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let urlString = "\(base)/models/\(escaped):generateContent"
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw RefinementError.invalidEndpoint(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeoutInterval

        let body = GenerateRequest(
            systemInstruction: .init(role: nil, parts: [.init(text: system)]),
            contents: [.init(role: "user", parts: [.init(text: text)])]
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// The reply text, or the provider error, `truncated` (hit the token
    /// limit) or `emptyResponse` (no text, for example a blocked reply).
    static func parse(data: Data, statusCode: Int) throws -> String {
        guard (200...299).contains(statusCode) else {
            throw RefinementError.providerError(statusCode: statusCode, message: decodeErrorMessage(from: data))
        }
        guard let response = try? JSONDecoder().decode(GenerateResponse.self, from: data) else {
            throw RefinementError.invalidResponse
        }
        guard let candidate = response.candidates?.first else { throw RefinementError.emptyResponse }
        if candidate.finishReason == "MAX_TOKENS" { throw RefinementError.truncated }
        let text = (candidate.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw RefinementError.emptyResponse }
        return text
    }

    /// Decodes a Google error body: {"error": {"code": ..., "message": ...}}.
    static func decodeErrorMessage(from data: Data) -> String {
        if let wrapped = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return wrapped.error.message
        }
        return String(data: data, encoding: .utf8) ?? "<unreadable>"
    }

    // MARK: - Wire Types

    private struct GenerateRequest: Encodable {
        let systemInstruction: Content
        let contents: [Content]

        struct Content: Encodable {
            let role: String?
            let parts: [Part]
        }

        struct Part: Encodable {
            let text: String
        }
    }

    private struct GenerateResponse: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }

        struct Content: Decodable {
            let parts: [Part]?
        }

        struct Part: Decodable {
            let text: String?
            let thought: Bool?
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let message: String
        }
    }
}
