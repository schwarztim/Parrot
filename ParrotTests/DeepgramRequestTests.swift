import XCTest

@testable import Parrot

/// Deepgram request and message shapes against canned payloads. No
/// network: requests are built and inspected, responses are fixed JSON.
final class DeepgramRequestTests: XCTestCase {

    private let key = "dg-test-key"
    private let samples = [Float](repeating: 0.1, count: 1_600)

    private func query(_ request: URLRequest) throws -> [URLQueryItem] {
        let url = try XCTUnwrap(request.url)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func values(_ items: [URLQueryItem], _ name: String) -> [String] {
        items.filter { $0.name == name }.compactMap(\.value)
    }

    // MARK: - Batch

    func testBatchRequestShape() throws {
        let request = try DeepgramSpeech.batchRequest(
            modelID: "nova-3", apiKey: key, samples: samples, options: TranscriptionOptions()
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.deepgram.com")
        XCTAssertEqual(request.url?.path, "/v1/listen")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token \(key)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(String(decoding: body.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(body.count, 44 + samples.count * 2, "16-bit mono WAV")

        let items = try query(request)
        XCTAssertEqual(values(items, "model"), ["nova-3"])
        XCTAssertEqual(values(items, "smart_format"), ["true"])
        XCTAssertEqual(values(items, "punctuate"), ["true"])
        XCTAssertEqual(values(items, "detect_language"), ["true"], "auto language asks Deepgram to detect")
        XCTAssertTrue(values(items, "language").isEmpty)
        XCTAssertTrue(values(items, "diarize").isEmpty)
        XCTAssertTrue(values(items, "encoding").isEmpty, "batch sends a WAV container, not raw PCM")
    }

    func testBatchLanguageAndDiarize() throws {
        let request = try DeepgramSpeech.batchRequest(
            modelID: "nova-2", apiKey: key, samples: samples,
            options: TranscriptionOptions(language: "de", diarize: true)
        )
        let items = try query(request)
        XCTAssertEqual(values(items, "language"), ["de"])
        XCTAssertTrue(values(items, "detect_language").isEmpty)
        XCTAssertEqual(values(items, "diarize"), ["true"])
    }

    func testMedicalModelIsEnglish() throws {
        let items = try query(DeepgramSpeech.batchRequest(
            modelID: "nova-2-medical", apiKey: key, samples: samples, options: TranscriptionOptions()
        ))
        XCTAssertEqual(values(items, "language"), ["en"])
    }

    func testVocabularyAsKeytermForNova3AndKeywordsForNova2() throws {
        let terms = ["Parrot", "FluidAudio"]
        let nova3 = try query(DeepgramSpeech.batchRequest(
            modelID: "nova-3", apiKey: key, samples: samples, options: TranscriptionOptions(), terms: terms
        ))
        XCTAssertEqual(values(nova3, "keyterm"), terms)
        XCTAssertTrue(values(nova3, "keywords").isEmpty)

        let nova2 = try query(DeepgramSpeech.batchRequest(
            modelID: "nova-2", apiKey: key, samples: samples, options: TranscriptionOptions(), terms: terms
        ))
        XCTAssertEqual(values(nova2, "keywords"), ["Parrot:2", "FluidAudio:2"])
        XCTAssertTrue(values(nova2, "keyterm").isEmpty)
    }

    func testKeytermsTruncatedToStayUnderTheURLLimit() throws {
        let terms = (0..<400).map { "LongVocabularyTerm\($0)" }
        let request = try DeepgramSpeech.batchRequest(
            modelID: "nova-3", apiKey: key, samples: samples, options: TranscriptionOptions(), terms: terms
        )
        let length = try XCTUnwrap(request.url?.absoluteString.count)
        XCTAssertLessThanOrEqual(length, DeepgramSpeech.urlLimit)
        let kept = values(try query(request), "keyterm")
        XCTAssertGreaterThan(kept.count, 10)
        XCTAssertLessThan(kept.count, terms.count)
        XCTAssertEqual(kept, Array(terms.prefix(kept.count)), "the first terms are kept, in order")
    }

    func testParseBatchWordsSpeakersAndLanguage() throws {
        let json = """
        {"metadata":{"request_id":"r1","duration":4.2,"channels":1},
         "results":{"channels":[{"detected_language":"en","alternatives":[{
           "transcript":"Hello there. How are you?","confidence":0.98,
           "words":[
             {"word":"hello","start":0.1,"end":0.4,"confidence":0.99,"speaker":0,"punctuated_word":"Hello"},
             {"word":"there","start":0.45,"end":0.8,"confidence":0.97,"speaker":0,"punctuated_word":"there."},
             {"word":"how","start":1.2,"end":1.4,"confidence":0.96,"speaker":1,"punctuated_word":"How"},
             {"word":"are","start":1.45,"end":1.6,"confidence":0.95,"speaker":1,"punctuated_word":"are"},
             {"word":"you","start":1.65,"end":1.9,"confidence":0.94,"speaker":1,"punctuated_word":"you?"}
           ]}]}]}}
        """
        let output = try DeepgramSpeech.parseBatch(Data(json.utf8), options: TranscriptionOptions())
        XCTAssertEqual(output.text, "Hello there. How are you?")
        XCTAssertEqual(output.language, "en")
        XCTAssertEqual(output.segments.map(\.text), ["Hello there.", "How are you?"])
        XCTAssertEqual(output.segments.map(\.speaker), ["0", "1"])
        XCTAssertEqual(output.segments.first?.start ?? -1, 0.1, accuracy: 0.001)
        XCTAssertEqual(output.segments.last?.end ?? -1, 1.9, accuracy: 0.001)
    }

    func testEngineSendsBatchAndWaitsOutAShortRateLimit() async throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"hello parrot","words":[]}]}]}}"#
        let calls = CallCounter()
        let engine = CloudVendorEngine(
            preset: CloudVoicePreset(vendor: .deepgram, modelID: "nova-3", realtimeModelID: "nova-3"),
            apiKey: key,
            send: { request in
                let count = calls.increment()
                let url = request.url!
                if count == 1 {
                    let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!
                    return (Data(#"{"err_msg":"slow down"}"#.utf8), response)
                }
                return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let output = try await engine.transcribe(samples, options: TranscriptionOptions(language: "en"))
        XCTAssertEqual(output.text, "hello parrot")
        XCTAssertEqual(calls.value, 2, "one retry after the 429")
    }

    func testEngineMapsHTTPErrorsForTheRetryPolicy() async throws {
        let engine = CloudVendorEngine(
            preset: CloudVoicePreset(vendor: .deepgram, modelID: "nova-3"),
            apiKey: key,
            send: { request in
                (Data(#"{"err_msg":"Invalid credentials."}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
        )
        do {
            _ = try await engine.transcribe(samples, options: TranscriptionOptions())
            XCTFail("expected a failure")
        } catch {
            let failure = TranscriptionFailure.classify(error)
            XCTAssertEqual(failure, .http(status: 401, message: "Invalid credentials."))
            XCTAssertFalse(failure.isRetryable)
        }
    }

    // MARK: - Realtime

    func testRealtimeRequestShape() throws {
        let request = try DeepgramSpeech.realtimeRequest(
            modelID: "nova-3", apiKey: key, options: TranscriptionOptions(), terms: ["Parrot"]
        )
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.deepgram.com")
        XCTAssertEqual(request.url?.path, "/v1/listen")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token \(key)")
        let items = try query(request)
        XCTAssertEqual(values(items, "encoding"), ["linear16"])
        XCTAssertEqual(values(items, "sample_rate"), ["16000"])
        XCTAssertEqual(values(items, "channels"), ["1"])
        XCTAssertEqual(values(items, "interim_results"), ["true"])
        XCTAssertEqual(values(items, "language"), ["multi"], "Nova 3 auto language streams as multi")
        XCTAssertEqual(values(items, "keyterm"), ["Parrot"])
        XCTAssertTrue(values(items, "detect_language").isEmpty)
    }

    func testRealtimeMessages() throws {
        let wire = DeepgramRealtimeProtocol()
        XCTAssertEqual(wire.audioMessage(Data([1, 2, 3, 4])), .data(Data([1, 2, 3, 4])), "audio goes as binary frames")
        XCTAssertEqual(wire.finishMessages(), [.text(#"{"type":"CloseStream"}"#)])
        XCTAssertEqual(wire.keepAliveMessage, .text(#"{"type":"KeepAlive"}"#))

        let interim = #"{"type":"Results","channel_index":[0,1],"duration":1.0,"start":0.0,"is_final":false,"speech_final":false,"channel":{"alternatives":[{"transcript":"hello wor","confidence":0.8,"words":[]}]}}"#
        XCTAssertEqual(wire.parse(.text(interim)), .interim("hello wor"))

        let final = #"{"type":"Results","channel_index":[0,1],"duration":1.5,"start":2.0,"is_final":true,"speech_final":true,"from_finalize":false,"channel":{"alternatives":[{"transcript":"hello world","confidence":0.9,"words":[]}]}}"#
        XCTAssertEqual(wire.parse(.text(final)), .final(text: "hello world", audioEnd: 3.5))

        let metadata = #"{"type":"Metadata","request_id":"r1","sha256":"x","created":"2026-10-10T00:00:00Z","duration":3.5,"channels":1}"#
        XCTAssertEqual(wire.parse(.text(metadata)), .finished)
        XCTAssertEqual(wire.parse(.text(#"{"type":"SpeechStarted","timestamp":0.5}"#)), .ignored)
        XCTAssertEqual(wire.parse(.text("not json")), .ignored)
    }
}

/// A thread-safe counter for fake senders.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
