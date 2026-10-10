import Foundation

// Third-party speech vendors with the user's own keys: OpenAI and Groq
// (batch, OpenAI-compatible), Deepgram and ElevenLabs (batch and
// realtime). Request building and response parsing are pure so tests can
// check them against canned payloads without the network. [ASR]

// MARK: - Shared Pieces

/// Sends a request; returns the body and the HTTP response.
typealias HTTPSender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

enum CloudHTTP {
    static let send: HTTPSender = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudTranscriberError.invalidResponse }
        return (data, http)
    }

    /// Throws a provider error for a non-2xx status, with the server's
    /// message when the body has one.
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        throw CloudTranscriberError.providerError(statusCode: response.statusCode, message: errorMessage(from: data))
    }

    /// Reads `{"error": {"message"}}`, `{"error": "..."}`, `{"err_msg"}` or
    /// `{"detail": {"message"}}`, else the raw body.
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
            if let message = object["err_msg"] as? String { return message }
            if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable>"
    }

    /// Seconds a 429 response asks the client to wait, if it says.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard response.statusCode == 429,
              let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return seconds
    }
}

/// A multipart/form-data body.
struct MultipartForm {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "parrot-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}

/// A timed word, with the vendor's speaker id when it labels speakers.
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float?
    var speaker: String?
}

enum WordSegmenter {
    /// Sentence segments from timed words; a change of speaker also starts
    /// a new segment. Speaker ids stay as the vendor sent them.
    static func segments(from words: [TimedWord]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let confidences = current.compactMap(\.confidence)
            segments.append(TranscriptSegment(
                text: current.map(\.text).joined(separator: " "),
                start: first.start,
                end: last.end,
                confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count),
                speaker: first.speaker
            ))
            current.removeAll()
        }

        for word in words {
            if let last = current.last,
               word.speaker != last.speaker || word.start - last.end > TranscriptSegmenter.pauseSplit {
                flush()
            }
            current.append(word)
            if let mark = word.text.last, ".?!".contains(mark) { flush() }
        }
        flush()
        return segments
    }
}

/// Vocabulary terms for vendors that accept them: each enabled entry's
/// corrected spelling, once.
enum VendorVocabulary {
    static func terms(from entries: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for entry in entries where entry.isEnabled {
            let term = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }
}

// MARK: - OpenAI and Groq

/// OpenAI's and Groq's audio endpoints (the same request shape). [ASR]
enum OpenAICompatibleSpeech {

    static func baseURL(for vendor: CloudVoiceVendor) -> String {
        switch vendor {
        case .groq: return "https://api.groq.com/openai/v1"
        default: return "https://api.openai.com/v1"
        }
    }

    /// Whisper models answer with timed segments; GPT-4o models only
    /// with text.
    static func supportsSegments(_ modelID: String) -> Bool {
        modelID.hasPrefix("whisper")
    }

    static func request(
        preset: CloudVoicePreset,
        apiKey: String,
        samples: [Float],
        options: TranscriptionOptions,
        terms: [String] = [],
        boundary: String = "parrot-\(UUID().uuidString)"
    ) throws -> URLRequest {
        let translate = options.translateToEnglish
        let path = translate ? "audio/translations" : "audio/transcriptions"
        guard let url = URL(string: "\(baseURL(for: preset.vendor))/\(path)") else {
            throw CloudTranscriberError.invalidEndpoint
        }
        var form = MultipartForm(boundary: boundary)
        form.add("model", preset.modelID)
        if !translate, let language = options.language {
            form.add("language", String(language.prefix(2)))
        }
        form.add("response_format", supportsSegments(preset.modelID) ? "verbose_json" : "json")
        form.add("temperature", "0")
        if !terms.isEmpty {
            // A short spelling hint; the prompt is capped by the vendors.
            form.add("prompt", String(terms.joined(separator: ", ").prefix(600)))
        }
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: WAVEncoder.encode(samples: samples))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        return request
    }

    static func parse(_ data: Data, options: TranscriptionOptions) throws -> TranscriptOutput {
        struct Response: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
            }
            let text: String
            let segments: [Segment]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let segments = (response.segments ?? []).compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TranscriptSegment(text: text, start: segment.start, end: segment.end)
        }
        return TranscriptOutput(
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            language: options.translateToEnglish ? "en" : options.language
        )
    }
}

// MARK: - Deepgram

/// Deepgram's listen endpoint: batch over HTTPS, realtime over a
/// WebSocket on the same path. [ASR]
enum DeepgramSpeech {

    static let batchBase = "https://api.deepgram.com/v1/listen"
    static let realtimeBase = "wss://api.deepgram.com/v1/listen"
    /// Keyterms are dropped from the end once the URL would pass this.
    static let urlLimit = 4_000

    /// Query items shared by batch and realtime.
    static func queryItems(
        modelID: String,
        options: TranscriptionOptions,
        realtime: Bool
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "model", value: modelID),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        if let language = options.language {
            items.append(URLQueryItem(name: "language", value: language))
        } else if modelID.hasSuffix("medical") {
            items.append(URLQueryItem(name: "language", value: "en"))
        } else if realtime {
            if modelID == "nova-3" { items.append(URLQueryItem(name: "language", value: "multi")) }
        } else {
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        if options.diarize {
            items.append(URLQueryItem(name: "diarize", value: "true"))
        }
        if realtime {
            items += [
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: "16000"),
                URLQueryItem(name: "channels", value: "1"),
                URLQueryItem(name: "interim_results", value: "true"),
            ]
        }
        return items
    }

    /// Adds vocabulary as `keyterm` (Nova 3) or `keywords` (Nova 2), as
    /// many as fit under the URL limit.
    static func url(base: String, items: [URLQueryItem], modelID: String, terms: [String]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw CloudTranscriberError.invalidEndpoint }
        components.queryItems = items
        let useKeyterm = modelID.hasPrefix("nova-3")
        var kept = 0
        for term in terms {
            let item = useKeyterm
                ? URLQueryItem(name: "keyterm", value: term)
                : URLQueryItem(name: "keywords", value: "\(term):2")
            var trial = components
            trial.queryItems = (components.queryItems ?? []) + [item]
            guard let length = trial.url?.absoluteString.count, length <= urlLimit else { break }
            components = trial
            kept += 1
        }
        if kept < terms.count {
            diagLog("[Parrot:Deepgram] Truncated keywords to \(kept) of \(terms.count) to stay under the request URL limit")
        }
        guard let url = components.url else { throw CloudTranscriberError.invalidEndpoint }
        return url
    }

    static func batchRequest(
        modelID: String,
        apiKey: String,
        samples: [Float],
        options: TranscriptionOptions,
        terms: [String] = []
    ) throws -> URLRequest {
        let url = try url(
            base: batchBase, items: queryItems(modelID: modelID, options: options, realtime: false),
            modelID: modelID, terms: terms
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = WAVEncoder.encode(samples: samples)
        return request
    }

    static func realtimeRequest(
        modelID: String,
        apiKey: String,
        options: TranscriptionOptions,
        terms: [String] = []
    ) throws -> URLRequest {
        let url = try url(
            base: realtimeBase, items: queryItems(modelID: modelID, options: options, realtime: true),
            modelID: modelID, terms: terms
        )
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Responses

    struct Word: Decodable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Float?
        let speaker: Int?
        let punctuated_word: String?

        var timed: TimedWord {
            TimedWord(
                text: punctuated_word ?? word, start: start, end: end,
                confidence: confidence, speaker: speaker.map(String.init)
            )
        }
    }

    struct Alternative: Decodable {
        let transcript: String
        let words: [Word]?
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]
        let detected_language: String?
    }

    static func parseBatch(_ data: Data, options: TranscriptionOptions) throws -> TranscriptOutput {
        struct Response: Decodable {
            struct Results: Decodable { let channels: [Channel] }
            let results: Results
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let channel = response.results.channels.first, let best = channel.alternatives.first else {
            throw CloudTranscriberError.invalidResponse
        }
        return TranscriptOutput(
            text: best.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: WordSegmenter.segments(from: (best.words ?? []).map(\.timed)),
            language: options.language ?? channel.detected_language
        )
    }
}

/// Deepgram's realtime messages. [ASR]
struct DeepgramRealtimeProtocol: RealtimeVendorProtocol {
    func audioMessage(_ pcm: Data) -> WebSocketMessage { .data(pcm) }

    func finishMessages() -> [WebSocketMessage] { [.text(#"{"type":"CloseStream"}"#)] }

    var keepAliveMessage: WebSocketMessage? { .text(#"{"type":"KeepAlive"}"#) }

    /// Deepgram sends Metadata, then closes, after its last results.
    var signalsFinished: Bool { true }

    func parse(_ message: WebSocketMessage) -> RealtimeEvent {
        guard case .text(let text) = message, let data = text.data(using: .utf8) else { return .ignored }
        struct Envelope: Decodable {
            let type: String?
            let is_final: Bool?
            let start: Double?
            let duration: Double?
            let channel: DeepgramSpeech.Channel?
            let description: String?
            let message: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return .ignored }
        switch envelope.type {
        case "Results":
            let transcript = envelope.channel?.alternatives.first?.transcript ?? ""
            if envelope.is_final == true {
                let end = envelope.start.flatMap { start in envelope.duration.map { start + $0 } }
                return .final(text: transcript, audioEnd: end)
            }
            return .interim(transcript)
        case "Metadata":
            return .finished
        case "Error":
            return .serverError(
                code: "error", message: envelope.description ?? envelope.message ?? "unknown", severity: .transient
            )
        default:
            return .ignored
        }
    }
}

// MARK: - ElevenLabs

/// ElevenLabs Scribe: batch upload and realtime socket. [ASR]
enum ElevenLabsSpeech {

    static let batchURL = "https://api.elevenlabs.io/v1/speech-to-text"
    static let realtimeBase = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    /// The vendor's per-term limits: under 50 characters and 5 words.
    static let maxTerms = 100

    static func usableTerms(_ terms: [String]) -> [String] {
        let banned = CharacterSet(charactersIn: "<>{}[]\\")
        return terms.filter {
            $0.count < 50 && $0.split(separator: " ").count <= 5 && $0.rangeOfCharacter(from: banned) == nil
        }
        .prefix(maxTerms).map { $0 }
    }

    static func batchRequest(
        modelID: String,
        apiKey: String,
        samples: [Float],
        options: TranscriptionOptions,
        terms: [String] = [],
        boundary: String = "parrot-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard let url = URL(string: batchURL) else { throw CloudTranscriberError.invalidEndpoint }
        var form = MultipartForm(boundary: boundary)
        form.add("model_id", modelID)
        if let language = options.language {
            form.add("language_code", language)
        }
        form.add("diarize", options.diarize ? "true" : "false")
        form.add("tag_audio_events", "false")
        form.add("timestamps_granularity", "word")
        for term in usableTerms(terms) {
            form.add("keyterms", term)
        }
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: WAVEncoder.encode(samples: samples))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        return request
    }

    struct Word: Decodable {
        let text: String
        let start: Double?
        let end: Double?
        let type: String?
        let speaker_id: String?
        let logprob: Double?
    }

    static func parseBatch(_ data: Data, options: TranscriptionOptions) throws -> TranscriptOutput {
        struct Response: Decodable {
            let text: String
            let language_code: String?
            let words: [Word]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let words = (response.words ?? []).compactMap { word -> TimedWord? in
            guard word.type == nil || word.type == "word", let start = word.start, let end = word.end else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return TimedWord(
                text: text, start: start, end: end,
                confidence: word.logprob.map { Float(exp($0)) }, speaker: word.speaker_id
            )
        }
        return TranscriptOutput(
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: WordSegmenter.segments(from: words),
            language: options.language ?? response.language_code
        )
    }

    static func realtimeRequest(
        modelID: String,
        apiKey: String,
        options: TranscriptionOptions,
        terms: [String] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(string: realtimeBase) else { throw CloudTranscriberError.invalidEndpoint }
        var items = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
        ]
        if let language = options.language {
            items.append(URLQueryItem(name: "language_code", value: language))
        }
        items += usableTerms(terms).map { URLQueryItem(name: "keyterms", value: $0) }
        components.queryItems = items
        guard let url = components.url else { throw CloudTranscriberError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    /// How each named server error is handled.
    static func severity(of code: String) -> RealtimeErrorSeverity {
        switch code {
        case "commit_throttled", "insufficient_audio_activity", "warning":
            return .diagnostic
        case "auth_error", "quota_exceeded", "unaccepted_terms", "chunk_size_exceeded",
             "input_error", "invalid_request":
            return .terminal
        default:
            // transcriber_error, resource_exhausted, rate_limited,
            // queue_overflow, session_time_limit_exceeded, error.
            return .transient
        }
    }
}

/// ElevenLabs' realtime messages. [ASR]
struct ElevenLabsRealtimeProtocol: RealtimeVendorProtocol {
    func audioMessage(_ pcm: Data) -> WebSocketMessage {
        .text(Self.chunk(base64: pcm.base64EncodedString(), commit: false))
    }

    /// An empty chunk that commits whatever the server holds.
    func finishMessages() -> [WebSocketMessage] {
        [.text(Self.chunk(base64: "", commit: true))]
    }

    var keepAliveMessage: WebSocketMessage? { nil }

    /// The first committed transcript after the final commit ends it.
    var signalsFinished: Bool { false }

    static func chunk(base64: String, commit: Bool) -> String {
        #"{"message_type":"input_audio_chunk","audio_base_64":"\#(base64)","commit":\#(commit),"sample_rate":16000}"#
    }

    func parse(_ message: WebSocketMessage) -> RealtimeEvent {
        guard case .text(let text) = message, let data = text.data(using: .utf8) else { return .ignored }
        struct Envelope: Decodable {
            let message_type: String?
            let text: String?
            let error: String?
            let warning: String?
            let words: [ElevenLabsSpeech.Word]?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let type = envelope.message_type ?? (envelope.warning != nil ? "warning" : nil)
        else { return .ignored }
        switch type {
        case "session_started":
            return .started
        case "partial_transcript":
            return .interim(envelope.text ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps":
            let end = envelope.words?.compactMap(\.end).max()
            return .final(text: envelope.text ?? "", audioEnd: end)
        case "committed_transcript_entities", "edited_transcript":
            return .ignored
        default:
            return .serverError(
                code: type,
                message: envelope.error ?? envelope.warning ?? "",
                severity: ElevenLabsSpeech.severity(of: type)
            )
        }
    }
}

// MARK: - Engine

/// A vendor preset in the router's engine shape: batch for every vendor,
/// live text for Deepgram and ElevenLabs. Nothing to download or load;
/// the router builds one from settings for each use. [ASR]
final class CloudVendorEngine: BatchTranscriptionEngine, StreamingTranscriptionEngine, @unchecked Sendable {
    let preset: CloudVoicePreset
    private let apiKey: String
    private let send: HTTPSender
    private let connector: WebSocketConnector
    private let lock = NSLock()
    private var terms: [String] = []

    init(
        preset: CloudVoicePreset,
        apiKey: String,
        send: @escaping HTTPSender = CloudHTTP.send,
        connector: @escaping WebSocketConnector = WebSocketConnectors.urlSession
    ) {
        self.preset = preset
        self.apiKey = apiKey
        self.send = send
        self.connector = connector
    }

    func isDownloaded() async -> Bool { true }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func load() async throws {}
    func unload() async {}

    func applyVocabulary(_ entries: [VocabularyEntry], enabled: Bool) async {
        setTerms(enabled ? VendorVocabulary.terms(from: entries) : [])
    }

    private func setTerms(_ terms: [String]) {
        lock.lock()
        self.terms = terms
        lock.unlock()
    }

    private var currentTerms: [String] {
        lock.lock()
        defer { lock.unlock() }
        return terms
    }

    /// The batch request for this preset.
    func batchRequest(_ samples: [Float], options: TranscriptionOptions) throws -> URLRequest {
        switch preset.vendor {
        case .openAI, .groq:
            return try OpenAICompatibleSpeech.request(
                preset: preset, apiKey: apiKey, samples: samples, options: options, terms: currentTerms
            )
        case .deepgram:
            return try DeepgramSpeech.batchRequest(
                modelID: preset.modelID, apiKey: apiKey, samples: samples, options: options, terms: currentTerms
            )
        case .elevenLabs:
            return try ElevenLabsSpeech.batchRequest(
                modelID: preset.modelID, apiKey: apiKey, samples: samples, options: options, terms: currentTerms
            )
        }
    }

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        let request = try batchRequest(samples, options: options)
        var (data, response) = try await send(request)
        // A rate limit with a short stated wait is waited out once.
        if let wait = CloudHTTP.retryAfter(response), wait <= 10 {
            diagLog("[Parrot:Cloud] \(preset.vendor.displayName) asked to retry in \(wait)s")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            (data, response) = try await send(request)
        }
        try CloudHTTP.check(data, response)
        switch preset.vendor {
        case .openAI, .groq: return try OpenAICompatibleSpeech.parse(data, options: options)
        case .deepgram: return try DeepgramSpeech.parseBatch(data, options: options)
        case .elevenLabs: return try ElevenLabsSpeech.parseBatch(data, options: options)
        }
    }

    /// Opens the vendor's live socket now (the preconnect) and returns the
    /// stream that feeds it.
    func startLiveStream(
        options: TranscriptionOptions,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> any LiveTranscriptionStream {
        guard let modelID = preset.realtimeModelID else {
            throw TranscriptionFailure.notConfigured("Live text for \(preset.vendor.displayName)")
        }
        let request: URLRequest
        let vendor: any RealtimeVendorProtocol
        switch preset.vendor {
        case .deepgram:
            request = try DeepgramSpeech.realtimeRequest(modelID: modelID, apiKey: apiKey, options: options, terms: currentTerms)
            vendor = DeepgramRealtimeProtocol()
        case .elevenLabs:
            request = try ElevenLabsSpeech.realtimeRequest(modelID: modelID, apiKey: apiKey, options: options, terms: currentTerms)
            vendor = ElevenLabsRealtimeProtocol()
        case .openAI, .groq:
            throw TranscriptionFailure.notConfigured("Live text for \(preset.vendor.displayName)")
        }
        let socket = RealtimeSocket(request: request, vendor: vendor, connector: connector, onUpdate: onUpdate)
        await socket.start()
        return RealtimeLiveStream(socket: socket)
    }
}
