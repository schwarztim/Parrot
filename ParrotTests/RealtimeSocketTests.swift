import XCTest

@testable import Parrot

// MARK: - Fake Socket

/// A WebSocket whose server side the test drives: it records what the
/// client sends and delivers scripted server frames or a drop.
final class FakeWebSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [WebSocketMessage] = []
    private let inbox: AsyncThrowingStream<WebSocketMessage, Error>
    private let feed: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    private var iterator: AsyncThrowingStream<WebSocketMessage, Error>.AsyncIterator
    private(set) var closed = false

    struct Dropped: Error {}

    init() {
        (inbox, feed) = AsyncThrowingStream<WebSocketMessage, Error>.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    var sent: [WebSocketMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames
    }

    /// Binary frames sent, in order.
    var sentAudio: [Data] {
        sent.compactMap { if case .data(let data) = $0 { return data } else { return nil } }
    }

    var sentText: [String] {
        sent.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
    }

    func send(_ message: WebSocketMessage) async throws {
        try record(message)
    }

    private func record(_ message: WebSocketMessage) throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw Dropped() }
        sentFrames.append(message)
    }

    func receive() async throws -> WebSocketMessage {
        guard let next = try await iterator.next() else { throw Dropped() }
        return next
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        feed.finish()
    }

    /// The server sends a frame.
    func serverSends(_ text: String) {
        feed.yield(.text(text))
    }

    /// The connection drops without a close handshake.
    func drop() {
        lock.lock()
        closed = true
        lock.unlock()
        feed.finish(throwing: Dropped())
    }
}

/// Hands out fake sockets; the first `failures` attempts fail to connect.
final class FakeConnector: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private(set) var attempts = 0
    private(set) var sockets: [FakeWebSocket] = []

    struct Refused: Error {}

    init(failures: Int = 0) {
        failuresLeft = failures
    }

    var connector: WebSocketConnector {
        { [self] _ in try self.connect() }
    }

    private func connect() throws -> any WebSocketConnection {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Refused()
        }
        let socket = FakeWebSocket()
        sockets.append(socket)
        return socket
    }

    func refuseAll() {
        lock.lock()
        failuresLeft = .max
        lock.unlock()
    }

    var socketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }

    func socket(_ index: Int) -> FakeWebSocket {
        lock.lock()
        defer { lock.unlock() }
        return sockets[index]
    }
}

/// Records the backoff waits instead of sleeping.
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in self.record(seconds) }
    }

    private func record(_ seconds: TimeInterval) {
        lock.lock()
        delays.append(seconds)
        lock.unlock()
    }

    var all: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }
}

/// Polls until `condition` holds or about 3 seconds pass.
func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

// MARK: - Tests

/// The shared realtime socket over a fake WebSocket: backoff, buffering,
/// replay after reconnect, the confirmed-text lock, and the batch fallback
/// when a realtime session gives no text.
final class RealtimeSocketTests: XCTestCase {

    /// 160 samples (10 ms) per frame keeps the arithmetic small.
    private func config(bufferCap: Int = 9_600_000) -> RealtimeSocket.Config {
        var config = RealtimeSocket.Config()
        config.chunkSamples = 160
        config.bufferCap = bufferCap
        config.finishTimeout = 1
        config.keepAliveInterval = nil
        return config
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "wss://realtime.invalid/v1/listen")!)
    }

    /// One 10 ms frame whose samples all equal `value`.
    private func frame(_ value: Float) -> [Float] {
        [Float](repeating: value, count: 160)
    }

    private func finalMessage(_ text: String, start: Double, duration: Double) -> String {
        #"{"type":"Results","start":\#(start),"duration":\#(duration),"is_final":true,"channel":{"alternatives":[{"transcript":"\#(text)"}]}}"#
    }

    private func interimMessage(_ text: String) -> String {
        #"{"type":"Results","start":0,"duration":0.1,"is_final":false,"channel":{"alternatives":[{"transcript":"\#(text)"}]}}"#
    }

    func testBackoffScheduleThenSessionLost() async {
        let connector = FakeConnector(failures: .max)
        let sleeps = SleepLog()
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(), connector: connector.connector,
            config: config(), sleep: sleeps.sleep
        )
        await socket.start()
        let lost = await eventually { await socket.state == .lost }
        XCTAssertTrue(lost, "the session is lost once every attempt fails")
        XCTAssertEqual(sleeps.all, [0.5, 1, 2, 5, 10])
        let delays = await socket.reconnectDelays
        XCTAssertEqual(delays, [0.5, 1, 2, 5, 10])
        XCTAssertEqual(connector.attempts, 6, "the first connect plus five retries")

        let result = await socket.finish()
        XCTAssertFalse(result.complete)
        XCTAssertFalse(result.isUsable)
    }

    func testAudioBeforeConnectIsBufferedThenSent() async {
        let connector = FakeConnector(failures: 1)
        let sleeps = SleepLog()
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(), connector: connector.connector,
            config: config(), sleep: sleeps.sleep
        )
        socket.append(frame(0.1))
        socket.append(frame(0.2))
        await socket.start()
        let open = await eventually { connector.socketCount == 1 && connector.socket(0).sentAudio.count == 2 }
        XCTAssertTrue(open)
        XCTAssertEqual(connector.socket(0).sentAudio, [PCM16.encode(frame(0.1)), PCM16.encode(frame(0.2))])
        XCTAssertEqual(sleeps.all, [0.5], "one backoff step before the second attempt worked")
        await socket.cancel()
    }

    func testReplayOfUnacknowledgedAudioAfterReconnect() async {
        let connector = FakeConnector()
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(), connector: connector.connector,
            config: config(), sleep: SleepLog().sleep
        )
        await socket.start()
        _ = await eventually { connector.socketCount == 1 }
        let first = connector.socket(0)
        for value in [Float(0.1), 0.2, 0.3] { socket.append(frame(value)) }
        let sentAll = await eventually { first.sentAudio.count == 3 }
        XCTAssertTrue(sentAll)

        // The server confirms the first 10 ms, then the connection drops.
        first.serverSends(finalMessage("hello", start: 0, duration: 0.01))
        let acked = await eventually { await socket.transcript.confirmedText == "hello" }
        XCTAssertTrue(acked)
        let buffered = await socket.bufferedBytes
        XCTAssertEqual(buffered, 2 * 160 * 2, "the confirmed frame left the buffer")
        first.drop()

        let reconnected = await eventually { connector.socketCount == 2 && connector.socket(1).sentAudio.count == 2 }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(
            connector.socket(1).sentAudio, [PCM16.encode(frame(0.2)), PCM16.encode(frame(0.3))],
            "only unconfirmed audio is replayed, in order"
        )
        let delays = await socket.reconnectDelays
        XCTAssertEqual(delays, [0.5])
        await socket.cancel()
    }

    func testConfirmedTextIsLockedAcrossAReconnect() async {
        let connector = FakeConnector()
        let updates = UpdateRecorder()
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(), connector: connector.connector,
            config: config(), sleep: SleepLog().sleep, onUpdate: { updates.append($0) }
        )
        await socket.start()
        _ = await eventually { connector.socketCount == 1 }
        socket.append(frame(0.1))
        let first = connector.socket(0)
        first.serverSends(finalMessage("hello", start: 0, duration: 0.01))
        first.serverSends(interimMessage("wor"))
        _ = await eventually { await socket.transcript.hypothesis == "wor" }
        first.drop()

        _ = await eventually { connector.socketCount == 2 }
        let afterDrop = await socket.transcript
        XCTAssertEqual(afterDrop.confirmedText, "hello", "final text survives the drop")
        XCTAssertEqual(afterDrop.hypothesis, "", "unconfirmed text is dropped; its audio is replayed")

        let second = connector.socket(1)
        second.serverSends(interimMessage("world"))
        second.serverSends(finalMessage("world", start: 0, duration: 0.01))
        _ = await eventually { await socket.transcript.confirmedText == "hello world" }

        // Finishing: CloseStream goes out, Metadata ends the session.
        let finishing = Task { await socket.finish() }
        _ = await eventually { second.sentText.contains(#"{"type":"CloseStream"}"#) }
        second.serverSends(#"{"type":"Metadata","request_id":"r","duration":0.02}"#)
        let result = await finishing.value
        XCTAssertEqual(result, RealtimeResult(text: "hello world", complete: true))
        XCTAssertTrue(updates.all.contains(LiveTranscriptUpdate(confirmed: "hello", hypothesis: "wor")))
        XCTAssertEqual(updates.all.last, LiveTranscriptUpdate(confirmed: "hello world", hypothesis: ""))
    }

    func testBufferCapDropsTheOldestAudio() async {
        let connector = FakeConnector(failures: .max)
        // Keep reconnecting from finishing so audio piles up.
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(), connector: connector.connector,
            config: config(bufferCap: 3 * 320),
            sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )
        await socket.start()
        for value in 1...6 { socket.append(frame(Float(value) / 10)) }
        let capped = await eventually { await socket.droppedChunks == 3 }
        XCTAssertTrue(capped)
        let buffered = await socket.bufferedBytes
        XCTAssertLessThanOrEqual(buffered, 3 * 320)
        await socket.cancel()
    }

    func testTerminalServerErrorLosesTheSession() async {
        let connector = FakeConnector()
        let socket = RealtimeSocket(
            request: request(), vendor: ElevenLabsRealtimeProtocol(), connector: connector.connector,
            config: config(), sleep: SleepLog().sleep
        )
        await socket.start()
        _ = await eventually { connector.socketCount == 1 }
        connector.socket(0).serverSends(#"{"message_type":"auth_error","error":"invalid key"}"#)
        let lost = await eventually { await socket.state == .lost }
        XCTAssertTrue(lost)
        XCTAssertEqual(connector.attempts, 1, "a terminal error never reconnects")
        let result = await socket.finish()
        XCTAssertFalse(result.complete)
    }

    func testRejectedKeyNeverReconnects() async {
        let sleeps = SleepLog()
        let attempts = CallCounter()
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(),
            connector: { _ in
                _ = attempts.increment()
                throw WebSocketRejected(status: 401)
            },
            config: config(), sleep: sleeps.sleep
        )
        await socket.start()
        let lost = await eventually { await socket.state == .lost }
        XCTAssertTrue(lost)
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(sleeps.all, [])
    }

    // MARK: - Fallback

    @MainActor
    func testEmptyRealtimeResultFallsBackToBatch() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let env = ASRTestEnvironment()
        defer { env.tearDown() }

        // A realtime session that ends cleanly with no text.
        let connector = FakeConnector()
        let socket = RealtimeSocket(
            request: request(), vendor: DeepgramRealtimeProtocol(), connector: connector.connector,
            config: config(), sleep: SleepLog().sleep
        )
        await socket.start()
        let stream = RealtimeLiveStream(socket: socket)
        _ = await eventually { connector.socketCount == 1 }
        stream.append(frame(0.1))
        let server = connector.socket(0)
        Task.detached {
            _ = await eventually { server.sentText.contains(#"{"type":"CloseStream"}"#) }
            server.serverSends(#"{"type":"Results","start":0,"duration":0.01,"is_final":true,"channel":{"alternatives":[{"transcript":""}]}}"#)
            server.serverSends(#"{"type":"Metadata","request_id":"r","duration":0.01}"#)
        }

        let model = VoiceModels.deepgramNova3
        let session = env.session(samples: try ASRFixture.samples(), mode: Mode(name: "Live", voiceModelID: model.id, realtimeOutput: true))
        session.realtimeModelID = model.id
        session.realtimeTranscript = Task { try? await stream.finish() }

        let result = try await TranscribeStage(services: env.services).run(session)
        XCTAssertEqual(result, .continue)
        XCTAssertTrue(session.text.lowercased().contains("hello"), "batch text: \(session.text)")
        XCTAssertEqual(session.voiceModelID, VoiceModels.parakeetV3.id)
        XCTAssertEqual(env.toasts.count, 1, "the batch pass ran for Deepgram (no key here) and fell back")
        XCTAssertTrue(env.toasts.first?.contains("Deepgram Nova 3 is not configured") == true, env.toasts.first ?? "")
    }

    @MainActor
    func testRealtimeTextIsUsedWithoutABatchPass() async throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let model = VoiceModels.elevenLabsScribe
        let session = env.session(samples: try ASRFixture.samples(), mode: Mode(name: "Live", voiceModelID: model.id, realtimeOutput: true))
        session.realtimeModelID = model.id
        session.realtimeTranscript = Task { "Hello from the live session." }

        let result = try await TranscribeStage(services: env.services).run(session)
        XCTAssertEqual(result, .continue)
        XCTAssertEqual(session.text, "Hello from the live session.")
        XCTAssertEqual(session.rawTranscript, "Hello from the live session.")
        XCTAssertEqual(session.voiceModelID, model.id)
        XCTAssertTrue(env.toasts.isEmpty, "no batch request, so no missing-key fallback")
    }
}

/// Collects live updates from the socket's callback.
final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LiveTranscriptUpdate] = []

    func append(_ update: LiveTranscriptUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    var all: [LiveTranscriptUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}
