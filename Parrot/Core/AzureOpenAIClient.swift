import Foundation

/// Chat-completions client for Azure OpenAI.
///
/// Sends POST {endpoint}/openai/deployments/{deployment}/chat/completions
/// ?api-version={apiVersion} with the key in the "api-key" header (Azure
/// key-based auth does not use Authorization: Bearer). The deployment name
/// is passed as the model parameter and placed in the URL; Azure ignores a
/// body-level model field on the dated API.
struct AzureOpenAIClient: RefinementClient {

    /// Resource endpoint, e.g. "https://my-resource.openai.azure.com".
    let endpoint: String
    let apiKey: String
    /// Dated data-plane API version. 2024-10-21 is the latest GA release.
    let apiVersion: String
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
        let url = try Self.chatURL(endpoint: endpoint, deployment: model, apiVersion: apiVersion)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
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

    static func chatURL(endpoint: String, deployment: String, apiVersion: String) throws -> URL {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw RefinementError.invalidEndpoint(urlString)
        }
        return url
    }

    /// Decodes an Azure error body: {"error": {"code": ..., "message": ...}}.
    static func decodeErrorMessage(from data: Data) -> String {
        if let wrapped = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return wrapped.error.message
        }
        return String(data: data, encoding: .utf8) ?? "<unreadable>"
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let message: String
        }
    }
}
