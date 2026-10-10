import XCTest

@testable import Parrot

/// Silence removal: the time map and trimmer as pure logic, then the real
/// path (Silero VAD, PreprocessAudioStage, Parakeet through TranscribeStage)
/// on the fixture padded with 3 s of silence on each side.
@MainActor
final class VADTrimTests: XCTestCase {

    private var env: ASRTestEnvironment!

    override func setUp() async throws {
        env = ASRTestEnvironment()
    }

    override func tearDown() async throws {
        env.tearDown()
        env = nil
    }

    // MARK: - Pure

    func testTrimJoinsMergedRegionsAndMapsTimesBack() {
        let samples = (0..<100).map(Float.init)
        let (trimmed, map) = SilenceTrimmer.trim(samples, keeping: [10..<20, 15..<30, 60..<70])

        XCTAssertEqual(trimmed, (10..<30).map(Float.init) + (60..<70).map(Float.init))
        XCTAssertEqual(map.pieces.count, 2)
        XCTAssertEqual(map.trimmedCount, 30)

        // Times are in seconds at 16 kHz; sample 25 of the trimmed audio
        // is sample 65 of the recording.
        let rate = AudioFrame.sampleRate
        XCTAssertEqual(map.originalTime(25 / rate) * rate, 65, accuracy: 0.5)
        XCTAssertEqual(map.originalTime(5 / rate) * rate, 15, accuracy: 0.5)
        XCTAssertEqual(map.originalTime(0) * rate, 10, accuracy: 0.5)
        // Past the trimmed end stays past the recording end.
        XCTAssertGreaterThan(map.originalTime(40 / rate) * rate, 100)
    }

    func testMergeClampsAndSortsRegions() {
        let merged = SilenceTrimmer.merge([50..<200, -5..<10, 8..<12], limit: 100)
        XCTAssertEqual(merged, [0..<12, 50..<100])
    }

    func testMapSegmentsShiftsIntoRecordingTime() {
        let map = SpeechTimeMap(
            pieces: [SpeechTimeMap.Piece(originalStart: 48_000, trimmedStart: 0, length: 32_000)],
            originalCount: 128_000
        )
        let mapped = map.mapSegments([TranscriptSegment(text: "hi", start: 0.5, end: 1.5)])
        XCTAssertEqual(mapped[0].start, 3.5, accuracy: 0.001)
        XCTAssertEqual(mapped[0].end, 4.5, accuracy: 0.001)
    }

    func testNormalizerRaisesQuietSpeechAndLeavesSilence() {
        let quiet = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 300 / 16_000)) * 0.01 }
        let input = ASRFixture.zeros(seconds: 1) + quiet
        let output = AudioNormalizer.normalize(input)

        XCTAssertEqual(output.count, input.count)
        let rms = { (slice: ArraySlice<Float>) -> Float in
            (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        XCTAssertLessThan(rms(output[0..<8_000]), 0.001, "silence must not be boosted")
        XCTAssertGreaterThan(rms(output[20_000..<32_000]), rms(input[20_000..<32_000]) * 3)
        XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0, 1)
    }

    // MARK: - Real Path

    func testPaddedFixtureIsTrimmedAndStillTranscribes() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        try await env.services.vad.prepare()

        let padded = try ASRFixture.padded(seconds: 3)
        let session = env.session(samples: padded)
        env.settings.transcription.silenceRemoval = true

        let preprocess = PreprocessAudioStage(services: env.services)
        let result = try await preprocess.run(session)
        XCTAssertEqual(result, .continue)

        let trimmed = try XCTUnwrap(session.transcriptionAudio, "silence was not removed")
        let map = try XCTUnwrap(session.speechTimeMap)
        XCTAssertLessThan(trimmed.count, padded.count - 4 * 16_000, "expected most of the 6 s of silence cut")
        XCTAssertEqual(session.samples.count, padded.count, "the recording itself must stay whole")
        XCTAssertGreaterThan(map.pieces.first?.originalStart ?? 0, 2 * 16_000)

        let transcribe = TranscribeStage(services: env.services)
        _ = try await transcribe.run(session)

        XCTAssertTrue(session.text.lowercased().contains("hello"), "unexpected transcript: \(session.text)")
        let first = try XCTUnwrap(session.segments.first)
        XCTAssertGreaterThan(first.start, 2.5, "segment times must map back to recording time")
        XCTAssertLessThan(session.segments.last?.end ?? 0, ASRFixture.seconds(padded))

        print(String(
            format: "[VADTrim] original %.2fs, trimmed %.2fs, first segment at %.2fs, transcript: %@",
            ASRFixture.seconds(padded), ASRFixture.seconds(trimmed), first.start, session.text
        ))
    }

    func testSilenceRemovalOffKeepsTheRecording() async throws {
        try await env.services.vad.prepare()
        env.settings.transcription.silenceRemoval = false
        env.settings.transcription.shortClipGate = false
        let session = env.session(samples: try ASRFixture.padded(seconds: 3))

        let result = try await PreprocessAudioStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
        XCTAssertNil(session.transcriptionAudio)
        XCTAssertNil(session.speechTimeMap)
    }
}
