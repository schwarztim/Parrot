import Foundation

/// "Test connection" for a language model: asks the provider for its model
/// list, which checks the key and the address without generating (or
/// paying for) any text. [LLM]
enum ConnectionTester {

    enum Outcome: Equatable {
        case success(modelCount: Int)
        case failure(String)

        var message: String {
            switch self {
            case .success(let count):
                return count > 0 ? "Connection successful (\(count) models available)" : "Connection successful"
            case .failure(let message):
                return message
            }
        }
    }

    /// The model-list request for an endpoint.
    static func request(for endpoint: LanguageModelEndpoint, azureAPIVersion: String) throws -> URLRequest {
        let base = endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString: String
        switch endpoint.provider {
        case .azureOpenAI:
            urlString = "\(base)/openai/models?api-version=\(azureAPIVersion)"
        default:
            urlString = "\(base)/models"
        }
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw RefinementError.invalidEndpoint(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let key = endpoint.apiKey
        switch endpoint.provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .azureOpenAI:
            request.setValue(key, forHTTPHeaderField: "api-key")
        case .openAI, .groq, .deepseek, .localServer, .openAICompatible:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }

    /// How many models a model-list reply names. Throws the provider error
    /// on HTTP failure.
    static func modelCount(data: Data, statusCode: Int, provider: RefinementProvider) throws -> Int {
        guard (200...299).contains(statusCode) else {
            throw RefinementError.providerError(statusCode: statusCode, message: OpenAICompatibleClient.decodeErrorMessage(from: data))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let list = object?["data"] as? [Any] { return list.count }
        if let list = object?["models"] as? [Any] { return list.count }
        return 0
    }

    /// Tests the model a mode or the global setting would use.
    static func test(
        languageModelID: String,
        settings: AppSettings,
        transport: any HTTPTransport = URLSessionTransport()
    ) async -> Outcome {
        do {
            let endpoint = try LanguageModelCatalog.endpoint(languageModelID, settings: settings)
            let request = try request(for: endpoint, azureAPIVersion: settings.refinement.azureOpenAIAPIVersion)
            let (data, response) = try await transport.send(request)
            return .success(modelCount: try modelCount(data: data, statusCode: response.statusCode, provider: endpoint.provider))
        } catch {
            return .failure("Connection failed. " + describe(error))
        }
    }

    /// A failure reason that never quotes a provider's auth message (it can
    /// echo part of the key).
    static func describe(_ error: Error) -> String {
        switch error {
        case RefinementError.providerError(let status, _) where status == 401 || status == 403:
            return "The API key was rejected (HTTP \(status))."
        case RefinementError.notConfigured:
            return "Enter the API key and model first."
        case let urlError as URLError:
            return urlError.code == .timedOut ? "The server did not answer in time." : "The server could not be reached."
        default:
            return error.localizedDescription
        }
    }
}
