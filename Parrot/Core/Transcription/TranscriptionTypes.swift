import Foundation

// MARK: - Options and Output

/// What a dictation asks of a recognizer, taken from its mode. [ASR]
struct TranscriptionOptions: Equatable, Sendable {
    /// Spoken language code, or nil to let the model detect it.
    var language: String?
    var translateToEnglish: Bool

    init(language: String? = nil, translateToEnglish: Bool = false) {
        self.language = language
        self.translateToEnglish = translateToEnglish
    }

    /// The mode's language and translate settings. "auto" and "" mean detect.
    init(mode: Mode?) {
        let code = mode?.language.trimmingCharacters(in: .whitespaces) ?? ""
        language = (code.isEmpty || code == LanguageCatalog.automatic) ? nil : code
        translateToEnglish = mode?.translateToEnglish ?? false
    }
}

/// A recognizer's answer: the text, plus timed segments when the engine has them.
struct TranscriptOutput: Equatable, Sendable {
    var text: String
    var segments: [TranscriptSegment] = []
    /// The language the engine was told or detected, when it reports one.
    var language: String?
}

// MARK: - Engine Protocols

/// Turns a whole recording into text. [ASR]
///
/// `TranscriptionRouter` owns the lifecycle: `download` (no time limit),
/// then `load` (single flight, 120 s limit), `transcribe` any number of
/// times, then `unload` once the keep-alive runs out. Cloud engines treat
/// every lifecycle call as a no-op.
protocol BatchTranscriptionEngine: AnyObject, Sendable {
    /// True when the model files are on disk. Cloud engines: always.
    func isDownloaded() async -> Bool
    /// Fetches the model files, reporting progress from 0 to 1.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Loads the model into memory and prewarms it. Safe to call when loaded.
    func load() async throws
    /// Frees the model's memory. `load` brings it back.
    func unload() async
    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput
    /// Points recognizer boosting at the vocabulary store. Engines without
    /// boosting ignore it.
    func applyVocabulary(_ entries: [VocabularyEntry], enabled: Bool) async
}

extension BatchTranscriptionEngine {
    func applyVocabulary(_ entries: [VocabularyEntry], enabled: Bool) async {}
}

/// Live text while recording. [ASR]
protocol StreamingTranscriptionEngine: AnyObject, Sendable {
    /// Opens a live stream on the loaded model. `onUpdate` runs off the
    /// main actor.
    func startLiveStream(
        options: TranscriptionOptions,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) -> Void
    ) async throws -> any LiveTranscriptionStream
}

/// The live text so far: words that will not change, then words that may.
struct LiveTranscriptUpdate: Equatable, Sendable {
    var confirmed: String
    var hypothesis: String
}

/// One recording's live text. Feed audio with `append`; end with `finish`
/// or `cancel`.
protocol LiveTranscriptionStream: AnyObject, Sendable {
    /// Called on the audio thread with 16 kHz mono samples. Returns at once.
    func append(_ samples: [Float])
    /// Transcribes the rest of the audio and returns the stream's whole text.
    func finish() async throws -> String
    /// Stops without a result.
    func cancel() async
}

// MARK: - Errors

/// Why a transcription failed, sorted so the retry policy and the cloud
/// fallback can decide what to do. [ASR]
enum TranscriptionFailure: LocalizedError, Equatable {
    /// The model is not loaded (or the download is still running).
    case engineNotReady
    case modelNotDownloaded(String)
    case loadTimedOut(String, TimeInterval)
    case loadFailed(String, String)
    /// A cloud provider is selected but its key or endpoint is missing.
    case notConfigured(String)
    case network(String)
    case timeout
    case http(status: Int, message: String)
    case invalidResponse(String)
    case cancelled
    /// The recognizer itself failed while running.
    case recognizer(String)

    /// Worth another try: the network, a busy or failing server, or a
    /// recognizer run that failed.
    var isRetryable: Bool {
        switch self {
        case .network, .timeout, .recognizer:
            return true
        case .http(let status, _):
            return status == 408 || status == 429 || status >= 500
        case .engineNotReady, .modelNotDownloaded, .loadTimedOut, .loadFailed,
             .notConfigured, .invalidResponse, .cancelled:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Transcription engine is not ready. Please wait for model download to complete."
        case .modelNotDownloaded(let name):
            return "\(name) is not downloaded. Download it in Models first."
        case .loadTimedOut(let name, let seconds):
            return "Loading \(name) timed out after \(Int(seconds)) seconds."
        case .loadFailed(let name, let message):
            return "Could not load \(name): \(message)"
        case .notConfigured(let name):
            return "\(name) is not configured."
        case .network(let message):
            return "Network error: \(message)"
        case .timeout:
            return "The transcription request timed out."
        case .http(let status, let message):
            return "HTTP \(status): \(message)"
        case .invalidResponse(let message):
            return "Invalid transcription response: \(message)"
        case .cancelled:
            return "Transcription was cancelled."
        case .recognizer(let message):
            return message
        }
    }

    /// Sorts any error from an engine or provider into a failure.
    static func classify(_ error: Error) -> TranscriptionFailure {
        if let failure = error as? TranscriptionFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            default:
                return .network(urlError.localizedDescription)
            }
        }
        if let cloud = error as? CloudTranscriberError {
            switch cloud {
            case .providerError(let status, let message):
                return .http(status: status, message: message)
            case .invalidResponse:
                return .invalidResponse(cloud.localizedDescription)
            case .invalidEndpoint:
                return .notConfigured(cloud.localizedDescription)
            }
        }
        if error is DecodingError {
            return .invalidResponse(error.localizedDescription)
        }
        if let engine = error as? TranscriptionEngineError, engine == .notReady {
            return .engineNotReady
        }
        if let legacy = error as? TranscriptionError, legacy == .engineNotReady {
            return .engineNotReady
        }
        return .recognizer(error.localizedDescription)
    }
}

// MARK: - Retry

/// Tries a transcription up to `maxAttempts` times. After failed attempt n
/// it waits `step * n` (200 ms, then 400 ms). A failure that is not
/// retryable ends the run at once. [ASR]
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var step: TimeInterval = 0.2

    static let standard = RetryPolicy()

    func delay(afterAttempt attempt: Int) -> TimeInterval {
        step * Double(attempt)
    }

    /// Runs `operation` (given the attempt number, from 1) until it
    /// succeeds or the policy gives up, then throws the last failure.
    func run<T>(
        sleep: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onFailure: (Int, TranscriptionFailure) -> Void = { _, _ in },
        _ operation: (Int) async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation(attempt)
            } catch {
                let failure = TranscriptionFailure.classify(error)
                onFailure(attempt, failure)
                guard failure.isRetryable, attempt < maxAttempts else { throw failure }
                try await sleep(delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }
}

// MARK: - Timeout

/// Waits for work that may not respond to cancellation (model loads), at
/// most a fixed time. [ASR]
enum Timeout {
    /// Returns `operation`'s result, or throws `failure` once `seconds`
    /// pass first. On a timeout the operation keeps running in the
    /// background; only the wait ends.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        failure: Error,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.claim() { continuation.resume(throwing: failure) }
            }
            Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
                timer.cancel()
            }
        }
    }
}

/// Lets exactly one of several racing tasks resume a continuation.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

// MARK: - Segments

/// Groups timed words into sentence segments. [ASR]
enum TranscriptSegmenter {
    /// A word and its span in seconds.
    struct Word: Equatable, Sendable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// A silence longer than this starts a new segment.
    static let pauseSplit: TimeInterval = 1.0

    /// Splits after sentence-ending punctuation or at a long pause.
    static func segments(from words: [Word]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            segments.append(TranscriptSegment(text: text, start: first.start, end: last.end))
            current.removeAll()
        }

        for word in words {
            if let last = current.last, word.start - last.end > pauseSplit {
                flush()
            }
            current.append(word)
            if let mark = word.text.last, ".?!".contains(mark) {
                flush()
            }
        }
        flush()
        return segments
    }
}
