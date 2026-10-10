import XCTest

@testable import Parrot

/// Every refinement failure keeps the raw transcript and explains why in a
/// toast; dictation is never lost. Runs the real RefineStage and
/// ConfiguredRefiner over canned HTTP replies (no network) on non-live
/// sessions, so nothing reaches delivery.
@MainActor
final class FallbackTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var services: AppServices!
    private var toasts: [String] = []

    private static let okReply = #"{"choices":[{"message":{"content":"Hello, world."},"finish_reason":"stop"}]}"#

    override func setUp() {
        super.setUp()
        suiteName = "ParrotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        settings.refinement.refinementEnabled = true
        settings.refinement.refinementProvider = .openAI
        settings.credentials.setKey("test-openai-key", for: .openAI)

        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-fallbacktests-\(UUID().uuidString)")
            .appendingPathComponent("vocabulary.json")
        services = AppServices(vocabulary: VocabularyManager(storageURL: storage))
        services.settings = settings
        toasts = []
        services.showTransientError = { [unowned self] message in self.toasts.append(message) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        services = nil
        settings = nil
        super.tearDown()
    }

    private func makeSession(_ text: String = "hello world", mode: Mode? = Mode(name: "Plain")) -> DictationSession {
        let session = DictationSession(trigger: .menu, mode: mode, source: .reprocess(1))
        session.rawTranscript = text
        session.text = text
        return session
    }

    @discardableResult
    private func run(_ session: DictationSession, transport: CannedTransport) async throws -> StageResult {
        services.refiner = ConfiguredRefiner(transport: transport)
        return try await RefineStage(services: services).run(session)
    }

    private func assertRaw(_ session: DictationSession, toast expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.text, "hello world", file: file, line: line)
        XCTAssertNil(session.llmText, file: file, line: line)
        XCTAssertEqual(toasts, [expected], file: file, line: line)
    }

    // MARK: - Success

    func testSuccessReplacesTheTextAndRecordsThePrompt() async throws {
        let session = makeSession()
        let result = try await run(session, transport: CannedTransport(body: Self.okReply))

        XCTAssertEqual(result, .continue)
        XCTAssertEqual(session.text, "Hello, world.")
        XCTAssertEqual(session.llmText, "Hello, world.")
        XCTAssertTrue(toasts.isEmpty)
        XCTAssertTrue(session.renderedPrompt?.hasSuffix("USER MESSAGE:\nhello world") == true)
    }

    func testPromptRenderedAtStartIsTheOneSent() async throws {
        let session = makeSession()
        session.prompt = RenderedPrompt(system: "RENDERED AT START", user: RenderedPrompt.transcriptPlaceholder)
        let transport = CannedTransport(body: Self.okReply)

        try await run(session, transport: transport)

        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], "RENDERED AT START")
        XCTAssertEqual(messages[1]["content"], "hello world")
    }

    // MARK: - Every Failure Falls Back

    func testRejectedKey() async throws {
        let session = makeSession()
        try await run(session, transport: CannedTransport(status: 401, body: #"{"error":{"message":"bad key test-ope****"}}"#))
        assertRaw(session, toast: "The language model rejected the API key. Pasted the raw transcript.")
    }

    func testServerError() async throws {
        let session = makeSession()
        try await run(session, transport: CannedTransport(status: 500, body: #"{"error":{"message":"overloaded"}}"#))
        assertRaw(session, toast: "Refinement failed, pasted raw transcript. HTTP 500: overloaded")
    }

    func testRateLimit() async throws {
        let session = makeSession()
        try await run(session, transport: CannedTransport(status: 429, body: "{}"))
        assertRaw(session, toast: "The language model is busy or over its limit. Pasted the raw transcript.")
    }

    func testNoNetwork() async throws {
        let session = makeSession()
        try await run(session, transport: CannedTransport(error: URLError(.notConnectedToInternet)))
        assertRaw(session, toast: "Could not reach the language model. Pasted the raw transcript.")
    }

    func testTimeout() async throws {
        let session = makeSession()
        try await run(session, transport: CannedTransport(error: URLError(.timedOut)))
        assertRaw(session, toast: "The language model took too long to answer. Pasted the raw transcript.")
    }

    func testContextOverflow() async throws {
        let session = makeSession()
        let cut = #"{"choices":[{"message":{"content":"Hello, wo"},"finish_reason":"length"}]}"#
        try await run(session, transport: CannedTransport(body: cut))
        assertRaw(session, toast: "The language model ran out of room and cut its answer short. Pasted the raw transcript.")
    }

    func testMissingModelSendsNothing() async throws {
        var mode = Mode(name: "Gone")
        mode.languageModelID = "custom/deleted-model"
        let session = makeSession(mode: mode)
        let transport = CannedTransport(body: Self.okReply)

        try await run(session, transport: transport)

        assertRaw(session, toast: "This mode's language model was not found. Pasted the raw transcript.")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingKey() async throws {
        settings.credentials.removeKey(for: .openAI)
        let session = makeSession()
        try await run(session, transport: CannedTransport(body: Self.okReply))
        assertRaw(session, toast: "The language model is not set up. Add its key in Language Models. Pasted the raw transcript.")
    }

    func testCancelledRequest() async throws {
        let session = makeSession()
        try await run(session, transport: CannedTransport(error: CancellationError()))
        assertRaw(session, toast: "Refinement was cancelled. Pasted the raw transcript.")
    }

    func testCancelledDictationKeepsQuiet() async throws {
        let session = makeSession()
        session.isCancelled = true
        try await run(session, transport: CannedTransport(error: URLError(.cancelled)))
        XCTAssertEqual(session.text, "hello world")
        XCTAssertTrue(toasts.isEmpty)
    }

    func testReplyThatIsOnlyReasoningFallsBack() async throws {
        let session = makeSession()
        let thinking = #"{"choices":[{"message":{"content":"<think>hmm, commas</think>"},"finish_reason":"stop"}]}"#
        try await run(session, transport: CannedTransport(body: thinking))
        assertRaw(session, toast: "Refinement failed, pasted raw transcript. The API returned an empty response with no content.")
    }

    func testThinkingIsStrippedFromAGoodReply() async throws {
        let session = makeSession()
        let reply = #"{"choices":[{"message":{"content":"<think>commas</think>\n<response>Hello, world.</response>"},"finish_reason":"stop"}]}"#
        try await run(session, transport: CannedTransport(body: reply))
        XCTAssertEqual(session.text, "Hello, world.")
    }

    // MARK: - When Refinement Runs

    func testVoiceModeNeverCallsTheModel() async throws {
        let session = makeSession(mode: ModePresets.make(.voice))
        let transport = CannedTransport(body: Self.okReply)
        try await run(session, transport: transport)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(session.text, "hello world")
        XCTAssertTrue(toasts.isEmpty)
    }

    func testRefinementOffSkipsUnlessTheModeNamesAModel() async throws {
        settings.refinement.refinementEnabled = false
        let plain = makeSession()
        let transport = CannedTransport(body: Self.okReply)
        try await run(plain, transport: transport)
        XCTAssertTrue(transport.requests.isEmpty)

        var mode = Mode(name: "Own model")
        mode.languageModelID = "openAI/gpt-4o-mini"
        let opted = makeSession(mode: mode)
        try await run(opted, transport: transport)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(opted.text, "Hello, world.")
    }

    func testEmptyTranscriptSendsNothing() async throws {
        let session = makeSession("   ")
        let transport = CannedTransport(body: Self.okReply)
        try await run(session, transport: transport)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
