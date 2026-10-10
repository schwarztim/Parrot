import XCTest

@testable import Parrot

/// ElevenLabs Scribe request and message shapes, plus the OpenAI and Groq
/// presets, against canned payloads. No network.
final class ElevenLabsMessageTests: XCTestCase {

    private let key = "el-test-key"
    private let samples = [Float](repeating: 0.1, count: 800)

    private func json(_ message: WebSocketMessage) throws -> [String: Any] {
        guard case .text(let text) = message else {
            XCTFail("expected a text frame")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func bodyText(_ request: URLRequest) throws -> String {
        String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    }

    private func field(_ name: String, _ value: String) -> String {
        "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    // MARK: - Realtime Messages

    func testAudioChunkMessage() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let object = try json(ElevenLabsRealtimeProtocol().audioMessage(pcm))
        XCTAssertEqual(object["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object["audio_base_64"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: object["audio_base_64"] as? String ?? ""), pcm)
        XCTAssertEqual(object["commit"] as? Bool, false)
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
    }

    func testFinishCommitsWithAnEmptyChunk() throws {
        let messages = ElevenLabsRealtimeProtocol().finishMessages()
        XCTAssertEqual(messages.count, 1)
        let object = try json(try XCTUnwrap(messages.first))
        XCTAssertEqual(object["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object["audio_base_64"] as? String, "")
        XCTAssertEqual(object["commit"] as? Bool, true)
        XCTAssertNil(ElevenLabsRealtimeProtocol().keepAliveMessage)
        XCTAssertFalse(ElevenLabsRealtimeProtocol().signalsFinished)
    }

    func testServerTranscriptMessages() {
        let wire = ElevenLabsRealtimeProtocol()
        XCTAssertEqual(
            wire.parse(.text(#"{"message_type":"session_started","session_id":"s1","config":{"sample_rate":16000,"model_id":"scribe_v2_realtime"}}"#)),
            .started
        )
        XCTAssertEqual(wire.parse(.text(#"{"message_type":"partial_transcript","text":"hello wor"}"#)), .interim("hello wor"))
        XCTAssertEqual(
            wire.parse(.text(#"{"message_type":"committed_transcript","text":"Hello world."}"#)),
            .final(text: "Hello world.", audioEnd: nil)
        )
        let stamped = #"""
        {"message_type":"committed_transcript_with_timestamps","text":"Hello world.","language_code":"en",
         "words":[{"text":"Hello","start":0.1,"end":0.4,"type":"word","speaker_id":"speaker_0","logprob":-0.1},
                  {"text":" ","start":0.4,"end":0.45,"type":"spacing","speaker_id":"speaker_0","logprob":0},
                  {"text":"world.","start":0.45,"end":0.9,"type":"word","speaker_id":"speaker_0","logprob":-0.2}]}
        """#
        XCTAssertEqual(wire.parse(.text(stamped)), .final(text: "Hello world.", audioEnd: 0.9))
        XCTAssertEqual(wire.parse(.data(Data([1]))), .ignored)
    }

    func testServerErrorsAreClassified() {
        let wire = ElevenLabsRealtimeProtocol()
        func severity(_ type: String) -> RealtimeErrorSeverity? {
            if case .serverError(let code, let message, let severity) = wire.parse(.text(#"{"message_type":"\#(type)","error":"boom"}"#)) {
                XCTAssertEqual(code, type)
                XCTAssertEqual(message, "boom")
                return severity
            }
            return nil
        }
        XCTAssertEqual(severity("commit_throttled"), .diagnostic)
        XCTAssertEqual(severity("insufficient_audio_activity"), .diagnostic)
        XCTAssertEqual(severity("transcriber_error"), .transient)
        XCTAssertEqual(severity("resource_exhausted"), .transient)
        XCTAssertEqual(severity("session_time_limit_exceeded"), .transient)
        XCTAssertEqual(severity("auth_error"), .terminal)
        XCTAssertEqual(severity("quota_exceeded"), .terminal)
        XCTAssertEqual(severity("unaccepted_terms"), .terminal)
        XCTAssertEqual(severity("chunk_size_exceeded"), .terminal)
    }

    func testRealtimeRequestShape() throws {
        let request = try ElevenLabsSpeech.realtimeRequest(
            modelID: "scribe_v2_realtime", apiKey: key, options: TranscriptionOptions(language: "fr"),
            terms: ["Parrot", "bad<term>"]
        )
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), key)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        XCTAssertEqual(values("model_id"), ["scribe_v2_realtime"])
        XCTAssertEqual(values("audio_format"), ["pcm_16000"])
        XCTAssertEqual(values("commit_strategy"), ["vad"])
        XCTAssertEqual(values("language_code"), ["fr"])
        XCTAssertEqual(values("keyterms"), ["Parrot"], "terms with banned characters are dropped")
    }

    // MARK: - Batch

    func testBatchRequestShape() throws {
        let request = try ElevenLabsSpeech.batchRequest(
            modelID: "scribe_v2", apiKey: key, samples: samples,
            options: TranscriptionOptions(language: "en", diarize: true),
            terms: ["Parrot", "Superwhisper"], boundary: "B"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let body = try bodyText(request)
        XCTAssertTrue(body.contains(field("model_id", "scribe_v2")))
        XCTAssertTrue(body.contains(field("language_code", "en")))
        XCTAssertTrue(body.contains(field("diarize", "true")))
        XCTAssertTrue(body.contains(field("timestamps_granularity", "word")))
        XCTAssertTrue(body.contains(field("keyterms", "Parrot")))
        XCTAssertTrue(body.contains(field("keyterms", "Superwhisper")))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav"))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testBatchWithoutLanguageLetsTheServerDetect() throws {
        let body = try bodyText(ElevenLabsSpeech.batchRequest(
            modelID: "scribe_v2", apiKey: key, samples: samples, options: TranscriptionOptions(), boundary: "B"
        ))
        XCTAssertFalse(body.contains("language_code"))
        XCTAssertTrue(body.contains(field("diarize", "false")))
    }

    func testParseBatchWordsAndSpeakers() throws {
        let json = #"""
        {"language_code":"en","language_probability":0.98,"text":"Hi Sam. Hello.",
         "words":[
           {"text":"Hi","start":0.0,"end":0.3,"type":"word","speaker_id":"speaker_0","logprob":-0.05},
           {"text":" ","start":0.3,"end":0.35,"type":"spacing","speaker_id":"speaker_0","logprob":0},
           {"text":"Sam.","start":0.35,"end":0.7,"type":"word","speaker_id":"speaker_0","logprob":-0.1},
           {"text":"(laughs)","start":0.8,"end":1.0,"type":"audio_event","speaker_id":"speaker_1","logprob":0},
           {"text":"Hello.","start":1.1,"end":1.5,"type":"word","speaker_id":"speaker_1","logprob":-0.2}
         ]}
        """#
        let output = try ElevenLabsSpeech.parseBatch(Data(json.utf8), options: TranscriptionOptions())
        XCTAssertEqual(output.text, "Hi Sam. Hello.")
        XCTAssertEqual(output.language, "en")
        XCTAssertEqual(output.segments.map(\.text), ["Hi Sam.", "Hello."])
        XCTAssertEqual(output.segments.map(\.speaker), ["speaker_0", "speaker_1"])
        let renumbered = DiarizationService.renumber(output.segments)
        XCTAssertEqual(renumbered.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    // MARK: - OpenAI and Groq Presets

    func testGroqWhisperRequestShape() throws {
        let preset = CloudVoicePreset(vendor: .groq, modelID: "whisper-large-v3-turbo")
        let request = try OpenAICompatibleSpeech.request(
            preset: preset, apiKey: "gq-test-key", samples: samples,
            options: TranscriptionOptions(language: "de"), terms: ["Parrot"], boundary: "B"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gq-test-key")
        let body = try bodyText(request)
        XCTAssertTrue(body.contains(field("model", "whisper-large-v3-turbo")))
        XCTAssertTrue(body.contains(field("language", "de")))
        XCTAssertTrue(body.contains(field("response_format", "verbose_json")))
        XCTAssertTrue(body.contains(field("prompt", "Parrot")))
    }

    func testTranslationUsesTheTranslationsEndpointWithoutLanguage() throws {
        let preset = CloudVoicePreset(vendor: .openAI, modelID: "whisper-1")
        let request = try OpenAICompatibleSpeech.request(
            preset: preset, apiKey: "oa-test-key", samples: samples,
            options: TranscriptionOptions(language: "fr", translateToEnglish: true), boundary: "B"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/translations")
        XCTAssertFalse(try bodyText(request).contains("name=\"language\""))
    }

    func testGPT4oAsksForPlainJSON() throws {
        let preset = CloudVoicePreset(vendor: .openAI, modelID: "gpt-4o-transcribe")
        let body = try bodyText(OpenAICompatibleSpeech.request(
            preset: preset, apiKey: "oa-test-key", samples: samples, options: TranscriptionOptions(), boundary: "B"
        ))
        XCTAssertTrue(body.contains(field("response_format", "json")))
    }

    func testParseVerboseJSONSegments() throws {
        let json = #"{"task":"transcribe","language":"english","duration":2.0,"text":" Hello world.","segments":[{"id":0,"start":0.0,"end":1.2,"text":" Hello world."}]}"#
        let output = try OpenAICompatibleSpeech.parse(Data(json.utf8), options: TranscriptionOptions(language: "en"))
        XCTAssertEqual(output.text, "Hello world.")
        XCTAssertEqual(output.segments, [TranscriptSegment(text: "Hello world.", start: 0, end: 1.2)])
        XCTAssertEqual(output.language, "en")
    }

    @MainActor
    func testVendorPresetsNeedTheirOwnKey() throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let router = env.services.transcription
        XCTAssertThrowsError(try router.engine(for: VoiceModels.elevenLabsScribe, settings: env.settings)) { error in
            guard case .notConfigured = TranscriptionFailure.classify(error) else {
                return XCTFail("expected notConfigured, got \(error)")
            }
        }
        env.settings.credentials.setKey("el-synthetic", for: .elevenlabs)
        let engine = try router.engine(for: VoiceModels.elevenLabsScribe, settings: env.settings)
        XCTAssertTrue(engine is CloudVendorEngine)
        XCTAssertTrue(engine is any StreamingTranscriptionEngine)
    }
}
