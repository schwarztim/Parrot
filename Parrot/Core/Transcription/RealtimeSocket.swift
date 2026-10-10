import Foundation

// MARK: - WebSocket Seam

/// One WebSocket frame.
enum WebSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// An open WebSocket. Production wraps `URLSessionWebSocketTask`; tests
/// pass a fake.
protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ message: WebSocketMessage) async throws
    /// Waits for the next frame. Throws when the socket closes or fails.
    func receive() async throws -> WebSocketMessage
    func close()
}

/// Opens a socket for a request, or throws when it cannot connect.
typealias WebSocketConnector = @Sendable (URLRequest) async throws -> any WebSocketConnection

enum WebSocketConnectors {
    /// Real sockets through URLSession.
    static let urlSession: WebSocketConnector = { request in
        try await URLSessionWebSocketConnection.connect(request)
    }
}

/// `URLSessionWebSocketTask` as a `WebSocketConnection`. [ASR]
final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    private init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    /// Opens the socket and waits for a ping round trip, so a bad key or
    /// host fails here rather than on the first audio frame.
    static func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        // The send buffer for one dictation can approach 9.6 MB.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        let connection = URLSessionWebSocketConnection(task: task)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return connection
    }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Vendor Protocol

/// How serious a server error is.
enum RealtimeErrorSeverity: Equatable, Sendable {
    /// Logged; the session carries on.
    case diagnostic
    /// The socket reconnects.
    case transient
    /// The session stops for good; the batch fallback takes over.
    case terminal
}

/// One parsed server message.
enum RealtimeEvent: Equatable, Sendable {
    case started
    /// Text that may still change.
    case interim(String)
    /// Text that will not change. `audioEnd` is where it ends, in seconds
    /// of the audio this connection received, when the vendor says.
    case final(text: String, audioEnd: TimeInterval?)
    /// The server has sent everything after the finish request.
    case finished
    case serverError(code: String, message: String, severity: RealtimeErrorSeverity)
    case ignored
}

/// A realtime vendor's wire format. [ASR]
protocol RealtimeVendorProtocol: Sendable {
    /// 16 kHz mono 16-bit little-endian PCM as one frame.
    func audioMessage(_ pcm: Data) -> WebSocketMessage
    /// Frames that ask the server to finalize, sent once at stop.
    func finishMessages() -> [WebSocketMessage]
    /// A frame that keeps an idle socket open, if the vendor needs one.
    var keepAliveMessage: WebSocketMessage? { get }
    /// True when the vendor sends `.finished` once it is done after the
    /// finish frames. Otherwise the first final after finishing ends it.
    var signalsFinished: Bool { get }
    func parse(_ message: WebSocketMessage) -> RealtimeEvent
}

// MARK: - Transcript State

/// The live text of one realtime session. Final text is locked: later
/// messages, reconnects and replays can only add to it. [ASR]
struct RealtimeTranscript: Equatable, Sendable {
    private(set) var confirmed: [String] = []
    private(set) var hypothesis = ""

    mutating func apply(_ event: RealtimeEvent) {
        switch event {
        case .interim(let text):
            hypothesis = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .final(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { confirmed.append(trimmed) }
            hypothesis = ""
        default:
            break
        }
    }

    /// The connection dropped: the unconfirmed tail is dropped too, since
    /// its audio is replayed and recognized again.
    mutating func connectionDropped() {
        hypothesis = ""
    }

    var confirmedText: String { confirmed.joined(separator: " ") }

    var update: LiveTranscriptUpdate {
        LiveTranscriptUpdate(confirmed: confirmedText, hypothesis: hypothesis)
    }
}

// MARK: - RealtimeSocket

/// What a finished realtime session produced.
struct RealtimeResult: Equatable, Sendable {
    var text: String
    /// False when the session was lost or never finished cleanly; its
    /// text may miss the end, so the batch pass replaces it.
    var complete: Bool

    /// True when the text can stand as the dictation's transcript.
    var isUsable: Bool { complete && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A realtime speech socket shared by Deepgram and ElevenLabs. [ASR]
///
/// - `start()` connects at record start (preconnect); audio appended before
///   the socket opens is buffered and sent once it does.
/// - Sent audio stays buffered until the server confirms text covering
///   it. The buffer holds at most `bufferCap` bytes (9.6 MB, about 5
///   minutes); beyond that the oldest audio is dropped and counted.
/// - On an unexpected drop it reconnects after 0.5, 1, 2, 5 and 10
///   seconds, then replays the unconfirmed audio. Confirmed text stays
///   locked. When every attempt fails the session is lost and `finish()`
///   reports it incomplete, so the batch pass takes over.
actor RealtimeSocket {

    struct Config: Sendable {
        var backoff: [TimeInterval] = [0.5, 1, 2, 5, 10]
        var bufferCap = 9_600_000
        /// Samples gathered before a frame is sent (100 ms).
        var chunkSamples = 1_600
        /// Longest wait for the last results after stop.
        var finishTimeout: TimeInterval = 4
        /// Seconds between keep-alive frames while no audio flows; nil
        /// turns keep-alive off.
        var keepAliveInterval: TimeInterval? = 4
    }

    enum State: Equatable, Sendable {
        case idle
        case connecting
        case open
        case reconnecting(attempt: Int)
        case closed
        case lost
    }

    private struct Chunk {
        var data: Data
        /// Seconds from the start of the recording.
        var start: TimeInterval
        var end: TimeInterval
    }

    private let request: URLRequest
    private let vendor: any RealtimeVendorProtocol
    private let connector: WebSocketConnector
    private let config: Config
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let onUpdate: @Sendable (LiveTranscriptUpdate) -> Void

    private let input: AsyncStream<[Float]>
    private let inputContinuation: AsyncStream<[Float]>.Continuation

    private(set) var state: State = .idle
    private(set) var transcript = RealtimeTranscript()
    /// Every reconnect wait taken, in order, for logs and tests.
    private(set) var reconnectDelays: [TimeInterval] = []
    private(set) var droppedChunks = 0
    private(set) var connectCount = 0
    /// Audio frames sent on any connection, replays included.
    private(set) var framesSent = 0

    private var connection: (any WebSocketConnection)?
    private var pending: [Chunk] = []
    /// How many `pending` chunks the current connection has been sent.
    private var sentIndex = 0
    /// Recording time where the current connection's audio starts.
    private var connectionOffset: TimeInterval = 0
    private var samplesQueued = 0
    private var gathered: [Float] = []
    private var isFlushing = false
    private var finishRequested = false
    private var finishSent = false
    private var serverFinished = false
    private var intentionalClose = false
    private var lastSend = Date()
    private var consecutiveEmptyFinals = 0

    private var pumpTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    init(
        request: URLRequest,
        vendor: any RealtimeVendorProtocol,
        connector: @escaping WebSocketConnector = WebSocketConnectors.urlSession,
        config: Config = Config(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void = { _ in }
    ) {
        self.request = request
        self.vendor = vendor
        self.connector = connector
        self.config = config
        self.sleep = sleep
        self.onUpdate = onUpdate
        (input, inputContinuation) = AsyncStream<[Float]>.makeStream()
    }

    /// Bytes of audio held for sending or replay.
    var bufferedBytes: Int { pending.reduce(0) { $0 + $1.data.count } }

    // MARK: - Lifecycle

    /// Connects in the background and starts taking audio. Returns at once.
    func start() {
        guard state == .idle else { return }
        state = .connecting
        let stream = input
        pumpTask = Task { [weak self] in
            for await samples in stream {
                await self?.gather(samples)
            }
        }
        reconnectTask = Task { [weak self] in
            await self?.connectFirstTime()
        }
        if let interval = config.keepAliveInterval, vendor.keepAliveMessage != nil {
            keepAliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    await self?.keepAliveIfIdle(interval: interval)
                }
            }
        }
    }

    /// Takes 16 kHz mono samples from the audio thread. Returns at once.
    nonisolated func append(_ samples: [Float]) {
        inputContinuation.yield(samples)
    }

    /// Sends the rest of the audio, asks the server to finalize, waits for
    /// the last results (at most `finishTimeout`), then closes.
    func finish() async -> RealtimeResult {
        inputContinuation.finish()
        await pumpTask?.value
        if !gathered.isEmpty {
            enqueue(gathered)
            gathered = []
        }
        finishRequested = true
        await flush()
        await sendFinishIfReady()

        let deadline = Date().addingTimeInterval(config.finishTimeout)
        while Date() < deadline, !isDone {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // A vendor that sends nothing more after the finish frames is done
        // when no unconfirmed text is left on an open connection.
        let complete = serverFinished || (state == .open && finishSent && transcript.hypothesis.isEmpty)
        closeIntentionally()
        if !complete {
            diagLog("[Parrot:Realtime] Session ended without the server's last results (state \(state))")
        }
        return RealtimeResult(text: transcript.confirmedText, complete: complete)
    }

    /// Stops without waiting for results.
    func cancel() {
        inputContinuation.finish()
        pumpTask?.cancel()
        closeIntentionally()
    }

    private var isDone: Bool {
        serverFinished || state == .lost || state == .closed
    }

    private func closeIntentionally() {
        intentionalClose = true
        reconnectTask?.cancel()
        keepAliveTask?.cancel()
        receiveTask?.cancel()
        connection?.close()
        connection = nil
        if state != .lost { state = .closed }
    }

    // MARK: - Connecting

    private func connectFirstTime() async {
        if await openConnection() { return }
        await reconnect()
    }

    /// Opens one connection; true on success.
    private func openConnection() async -> Bool {
        let started = Date()
        do {
            let socket = try await connector(request)
            guard !intentionalClose else {
                socket.close()
                return false
            }
            connectCount += 1
            connection = socket
            sentIndex = 0
            connectionOffset = pending.first?.start ?? Double(samplesQueued) / AudioFrame.sampleRate
            state = .open
            lastSend = Date()
            diagLog("[Parrot:Realtime] Connected in \(String(format: "%.2f", Date().timeIntervalSince(started)))s, replaying \(pending.count) chunks")
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(socket)
            }
            await flush()
            await sendFinishIfReady()
            return true
        } catch {
            diagLog("[Parrot:Realtime] Connect failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Waits out each backoff step and tries again; the session is lost
    /// when every attempt fails.
    private func reconnect() async {
        for (index, delay) in config.backoff.enumerated() {
            guard !intentionalClose else { return }
            state = .reconnecting(attempt: index + 1)
            reconnectDelays.append(delay)
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !intentionalClose else { return }
            if await openConnection() { return }
        }
        guard !intentionalClose else { return }
        state = .lost
        diagLog("[Parrot:Realtime] Reconnect attempts exhausted, session lost")
    }

    private func connectionLost(_ socket: any WebSocketConnection, error: Error?) {
        guard socket === connection, !intentionalClose else { return }
        if finishSent && serverFinished { return }
        diagLog("[Parrot:Realtime] Unexpected disconnect: \(error?.localizedDescription ?? "closed")")
        connection = nil
        socket.close()
        transcript.connectionDropped()
        onUpdate(transcript.update)
        finishSent = false
        state = .reconnecting(attempt: 0)
        reconnectTask = Task { [weak self] in
            await self?.reconnect()
        }
    }

    // MARK: - Receiving

    private func receiveLoop(_ socket: any WebSocketConnection) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                handle(vendor.parse(message), from: socket)
            } catch {
                if finishSent, socket === connection {
                    // The server closed after the finish request: it is done.
                    serverFinished = true
                }
                connectionLost(socket, error: error)
                return
            }
        }
    }

    private func handle(_ event: RealtimeEvent, from socket: any WebSocketConnection) {
        guard socket === connection else { return }
        switch event {
        case .interim:
            transcript.apply(event)
            onUpdate(transcript.update)
        case .final(let text, let audioEnd):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                consecutiveEmptyFinals += 1
                if consecutiveEmptyFinals == 3 || (consecutiveEmptyFinals > 3 && consecutiveEmptyFinals % 10 == 3) {
                    diagLog("[Parrot:Realtime] \(consecutiveEmptyFinals) empty commits in a row: the server hears sound but no speech")
                }
            } else {
                consecutiveEmptyFinals = 0
            }
            transcript.apply(event)
            acknowledge(through: audioEnd.map { connectionOffset + $0 })
            onUpdate(transcript.update)
            if finishSent, !vendor.signalsFinished { serverFinished = true }
        case .finished:
            if finishSent { serverFinished = true }
        case .serverError(let code, let message, let severity):
            diagLog("[Parrot:Realtime] Server \(severity) error \(code): \(message)")
            switch severity {
            case .diagnostic:
                break
            case .transient:
                connectionLost(socket, error: nil)
            case .terminal:
                intentionalClose = true
                connection?.close()
                connection = nil
                state = .lost
            }
        case .started, .ignored:
            break
        }
    }

    /// Drops audio the server has turned into final text. Without a time
    /// from the vendor, everything sent so far counts as covered.
    private func acknowledge(through time: TimeInterval?) {
        var covered = 0
        if let time {
            while covered < sentIndex, pending[covered].end <= time + 0.001 { covered += 1 }
        } else {
            covered = sentIndex
        }
        guard covered > 0 else { return }
        pending.removeFirst(covered)
        sentIndex -= covered
    }

    // MARK: - Sending

    private func gather(_ samples: [Float]) async {
        gathered.append(contentsOf: samples)
        guard gathered.count >= config.chunkSamples else { return }
        enqueue(gathered)
        gathered = []
        await flush()
    }

    private func enqueue(_ samples: [Float]) {
        let start = Double(samplesQueued) / AudioFrame.sampleRate
        samplesQueued += samples.count
        let end = Double(samplesQueued) / AudioFrame.sampleRate
        pending.append(Chunk(data: PCM16.encode(samples), start: start, end: end))

        var dropped = 0
        while bufferedBytes > config.bufferCap, pending.count > 1 {
            pending.removeFirst()
            dropped += 1
        }
        if dropped > 0 {
            sentIndex = max(0, sentIndex - dropped)
            if droppedChunks / 50 != (droppedChunks + dropped) / 50 || droppedChunks == 0 {
                diagLog("[Parrot:Realtime] Send buffer full, dropped \(droppedChunks + dropped) oldest chunks so far")
            }
            droppedChunks += dropped
        }
    }

    /// Sends every chunk the open connection has not had yet, in order.
    private func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while state == .open, let socket = connection, sentIndex < pending.count {
            let chunk = pending[sentIndex]
            do {
                try await socket.send(vendor.audioMessage(chunk.data))
                framesSent += 1
                lastSend = Date()
                if socket === connection { sentIndex += 1 }
            } catch {
                connectionLost(socket, error: error)
                return
            }
        }
    }

    private func sendFinishIfReady() async {
        guard finishRequested, !finishSent, state == .open, let socket = connection, sentIndex >= pending.count else {
            return
        }
        finishSent = true
        for message in vendor.finishMessages() {
            do {
                try await socket.send(message)
            } catch {
                connectionLost(socket, error: error)
                return
            }
        }
    }

    private func keepAliveIfIdle(interval: TimeInterval) async {
        guard state == .open, let socket = connection, let message = vendor.keepAliveMessage,
              Date().timeIntervalSince(lastSend) >= interval
        else { return }
        try? await socket.send(message)
        lastSend = Date()
    }
}

// MARK: - PCM

/// 16-bit little-endian PCM, the realtime vendors' input format.
enum PCM16 {
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - Live Stream

/// A realtime socket as a live text stream for the router and the live
/// participant. `finish()` returns the session's final text and throws
/// `RealtimeSessionIncomplete` when the session cannot be trusted. [ASR]
final class RealtimeLiveStream: LiveTranscriptionStream, @unchecked Sendable {
    let socket: RealtimeSocket

    init(socket: RealtimeSocket) {
        self.socket = socket
    }

    func append(_ samples: [Float]) {
        socket.append(samples)
    }

    func finish() async throws -> String {
        let result = await socket.finish()
        guard result.complete else { throw RealtimeSessionIncomplete(text: result.text) }
        return result.text
    }

    func cancel() async {
        await socket.cancel()
    }
}

/// The realtime session was lost or ended before the server's last
/// results; `text` is whatever was confirmed.
struct RealtimeSessionIncomplete: Error, Equatable {
    let text: String
}
