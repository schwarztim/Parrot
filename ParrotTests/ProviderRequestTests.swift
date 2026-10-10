import XCTest

@testable import Parrot

/// Records requests and answers with canned replies. No network.
final class CannedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var status: Int
    var body: Data
    var error: Error?

    init(status: Int = 200, body: String = "{}", error: Error? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.error = error
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// Request shape per provider, model id resolution and reply parsing, all
/// against canned payloads. Keys are synthetic and live in memory only.
@MainActor
final class ProviderRequestTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        suiteName = "ParrotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        settings = nil
        super.tearDown()
    }

    private static let chatReply = #"{"choices":[{"message":{"role":"assistant","content":"Hello."},"finish_reason":"stop"}]}"#

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func refine(_ id: String, transport: CannedTransport) async throws -> String {
        try await RefinementService.refine(
            RefinementRequest(system: "SYSTEM PROMPT", user: "raw words", languageModelID: id),
            settings: settings, transport: transport
        )
    }

    private func assertChatBody(_ request: URLRequest, model: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, model, file: file, line: line)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]], file: file, line: line)
        XCTAssertEqual(messages, [["role": "system", "content": "SYSTEM PROMPT"], ["role": "user", "content": "raw words"]], file: file, line: line)
    }

    // MARK: - Request Shapes

    func testOpenAIGlobalProvider() async throws {
        settings.refinement.refinementProvider = .openAI
        settings.refinement.openAIModel = "gpt-4o-mini"
        settings.credentials.setKey("test-openai-key", for: .openAI)
        let transport = CannedTransport(body: Self.chatReply)

        let text = try await refine("", transport: transport)

        XCTAssertEqual(text, "Hello.")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        try assertChatBody(request, model: "gpt-4o-mini")
    }

    func testGroqUsesItsEndpointAndKey() async throws {
        settings.credentials.setKey("test-groq-key", for: .groq)
        let transport = CannedTransport(body: Self.chatReply)

        _ = try await refine("groq/openai/gpt-oss-20b", transport: transport)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-groq-key")
        try assertChatBody(request, model: "openai/gpt-oss-20b")
    }

    func testDeepSeekUsesItsEndpoint() async throws {
        settings.credentials.setKey("test-deepseek-key", for: .deepseek)
        let transport = CannedTransport(body: Self.chatReply)

        _ = try await refine("deepseek/deepseek-chat", transport: transport)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-deepseek-key")
        try assertChatBody(request, model: "deepseek-chat")
    }

    func testGeminiUsesGenerateContentWithTheKeyInAHeader() async throws {
        settings.credentials.setKey("test-gemini-key", for: .gemini)
        let reply = #"""
        {"candidates":[{"content":{"role":"model","parts":[{"text":"weighing commas","thought":true},{"text":"Hello."}]},"finishReason":"STOP"}]}
        """#
        let transport = CannedTransport(body: reply)

        let text = try await refine("gemini/gemini-2.5-flash", transport: transport)

        XCTAssertEqual(text, "Hello.", "thought parts are skipped")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        XCTAssertNil(request.url?.query, "the key never goes in the URL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-gemini-key")
        let json = try body(request)
        let system = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        XCTAssertEqual((system["parts"] as? [[String: String]])?.first?["text"], "SYSTEM PROMPT")
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        XCTAssertEqual((contents.first?["parts"] as? [[String: String]])?.first?["text"], "raw words")
    }

    func testAnthropicMessagesShape() async throws {
        settings.credentials.setKey("test-anthropic-key", for: .anthropic)
        let reply = #"{"content":[{"type":"text","text":"Hello."}],"stop_reason":"end_turn"}"#
        let transport = CannedTransport(body: reply)

        let text = try await refine("anthropic/claude-haiku-4-5", transport: transport)

        XCTAssertEqual(text, "Hello.")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-anthropic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["system"] as? String, "SYSTEM PROMPT")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(json["messages"] as? [[String: String]], [["role": "user", "content": "raw words"]])
    }

    func testAzureDeploymentURLAndKeyHeader() async throws {
        settings.refinement.azureOpenAIEndpoint = "https://example-res.openai.azure.com/"
        settings.credentials.setKey("test-azure-key", for: .azureOpenAI)
        let transport = CannedTransport(body: Self.chatReply)

        _ = try await refine("azureOpenAI/chat-dep", transport: transport)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example-res.openai.azure.com/openai/deployments/chat-dep/chat/completions?api-version=2024-10-21"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "test-azure-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCustomCompatibleEndpointUsesItsBaseURLAndSharedKey() async throws {
        let custom = CustomLanguageModel(name: "Mixtral", provider: .openAICompatible, modelID: "mixtral", baseURL: "https://llm.example.net/v1/")
        settings.refinement.customModels = [custom]
        settings.credentials.setKey("test-compatible-key", for: .openAICompatible)
        let transport = CannedTransport(body: Self.chatReply)

        _ = try await refine(custom.languageModelID, transport: transport)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://llm.example.net/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-compatible-key")
        try assertChatBody(request, model: "mixtral")
        XCTAssertFalse(LanguageModelCatalog.isLocal(custom.languageModelID, settings: settings))
    }

    func testLocalServerSendsNoKeyAndCountsAsLocal() async throws {
        settings.refinement.refinementProvider = .localServer
        settings.refinement.localServerModel = "llama3.2:3b"
        let transport = CannedTransport(body: Self.chatReply)

        _ = try await refine("", transport: transport)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(LanguageModelCatalog.isLocal("", settings: settings))
    }

    func testLoopbackCompatibleEndpointCountsAsLocal() {
        XCTAssertTrue(LanguageModelCatalog.isLoopback("http://localhost:1234/v1"))
        XCTAssertTrue(LanguageModelCatalog.isLoopback("http://127.0.0.1:8080/v1"))
        XCTAssertTrue(LanguageModelCatalog.isLoopback("http://studio.local:1234/v1"))
        XCTAssertFalse(LanguageModelCatalog.isLoopback("https://api.example.com/v1"))
        settings.refinement.compatibleModel = "qwen"
        XCTAssertTrue(LanguageModelCatalog.isLocal("openAICompatible/qwen", settings: settings))
    }

    // MARK: - Model IDs

    func testUnknownIDsAreNotFound() {
        for id in ["nope", "custom/missing", "groq/", "unknownprovider/x"] {
            XCTAssertThrowsError(try LanguageModelCatalog.resolve(id, settings: settings), id) { error in
                guard case RefinementError.modelNotFound = error else {
                    return XCTFail("\(id): expected modelNotFound, got \(error)")
                }
            }
        }
    }

    func testMissingKeyIsNotConfigured() {
        XCTAssertThrowsError(try LanguageModelCatalog.resolve("groq/llama-3.3-70b-versatile", settings: settings)) { error in
            guard case RefinementError.notConfigured = error else { return XCTFail("got \(error)") }
        }
    }

    func testChoicesListDefaultConfiguredProvidersAndCustomModels() {
        settings.credentials.setKey("test-groq-key", for: .groq)
        let custom = CustomLanguageModel(name: "Mine", provider: .openAI, modelID: "gpt-5-mini")
        settings.refinement.customModels = [custom]

        let ids = LanguageModelCatalog.choices(settings: settings, including: "custom/gone").map(\.id)

        XCTAssertEqual(ids.first, "")
        XCTAssertTrue(ids.contains("groq/llama-3.3-70b-versatile"))
        XCTAssertFalse(ids.contains { $0.hasPrefix("openAI/") }, "no OpenAI key, so not listed")
        XCTAssertTrue(ids.contains(custom.languageModelID))
        XCTAssertEqual(ids.last, "custom/gone", "a mode's missing model stays visible")
    }

    func testCustomModelsPersistWithoutSecrets() throws {
        settings.refinement.customModels = [CustomLanguageModel(id: "abc", name: "Mine", provider: .groq, modelID: "m")]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let raw = try XCTUnwrap(defaults.data(forKey: "parrot.llm.customModels"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).lowercased().contains("key"))

        let reloaded = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(reloaded.refinement.customModels.first?.id, "abc")
        XCTAssertEqual(reloaded.refinement.customModels.first?.provider, .groq)
    }

    // MARK: - Reply Parsing

    func testCutShortRepliesAreTruncated() {
        let openAI = Data(#"{"choices":[{"message":{"content":"Hel"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertThrowsError(try ChatCompletionResponse.content(from: openAI, statusCode: 200, errorMessage: { _ in "" })) {
            guard case RefinementError.truncated = $0 else { return XCTFail("got \($0)") }
        }
        let anthropic = Data(#"{"content":[{"type":"text","text":"Hel"}],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertThrowsError(try AnthropicClient.parse(data: anthropic, statusCode: 200)) {
            guard case RefinementError.truncated = $0 else { return XCTFail("got \($0)") }
        }
        let gemini = Data(#"{"candidates":[{"content":{"parts":[{"text":"Hel"}]},"finishReason":"MAX_TOKENS"}]}"#.utf8)
        XCTAssertThrowsError(try GeminiClient.parse(data: gemini, statusCode: 200)) {
            guard case RefinementError.truncated = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testErrorBodiesDecodePerProvider() {
        let gemini = Data(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#.utf8)
        XCTAssertEqual(GeminiClient.decodeErrorMessage(from: gemini), "API key not valid.")
        XCTAssertThrowsError(try GeminiClient.parse(data: gemini, statusCode: 400)) {
            guard case RefinementError.providerError(400, "API key not valid.") = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testMalformedSuccessIsInvalidResponse() {
        XCTAssertThrowsError(try ChatCompletionResponse.content(from: Data("<html>".utf8), statusCode: 200, errorMessage: { _ in "" })) {
            guard case RefinementError.invalidResponse = $0 else { return XCTFail("got \($0)") }
        }
    }

    // MARK: - Connection Test

    func testConnectionTestListsModelsWithoutGenerating() async throws {
        settings.credentials.setKey("test-groq-key", for: .groq)
        let transport = CannedTransport(body: #"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#)

        let outcome = await ConnectionTester.test(languageModelID: "groq/llama-3.3-70b-versatile", settings: settings, transport: transport)

        XCTAssertEqual(outcome, .success(modelCount: 2))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-groq-key")
        XCTAssertNil(request.httpBody)
    }

    func testConnectionTestRequestPerProvider() throws {
        func url(_ provider: RefinementProvider, _ base: String) throws -> URLRequest {
            try ConnectionTester.request(
                for: LanguageModelEndpoint(provider: provider, model: "m", baseURL: base, apiKey: "test-key", isLocal: false),
                azureAPIVersion: "2024-10-21"
            )
        }
        let anthropic = try url(.anthropic, AnthropicClient.defaultBaseURL)
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let gemini = try url(.gemini, GeminiClient.defaultBaseURL)
        XCTAssertEqual(gemini.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")

        let azure = try url(.azureOpenAI, "https://res.openai.azure.com")
        XCTAssertEqual(azure.url?.absoluteString, "https://res.openai.azure.com/openai/models?api-version=2024-10-21")
        XCTAssertEqual(azure.value(forHTTPHeaderField: "api-key"), "test-key")
    }

    func testRejectedKeyNeverEchoesTheProviderMessage() async {
        settings.credentials.setKey("test-openai-key", for: .openAI)
        let transport = CannedTransport(status: 401, body: #"{"error":{"message":"Incorrect API key provided: test-ope****-key"}}"#)

        let outcome = await ConnectionTester.test(languageModelID: "openAI/gpt-4o-mini", settings: settings, transport: transport)

        XCTAssertEqual(outcome, .failure("Connection failed. The API key was rejected (HTTP 401)."))
        XCTAssertFalse(outcome.message.contains("test-ope"))
    }
}
