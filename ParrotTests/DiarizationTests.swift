import XCTest

@testable import Parrot

/// A diarizer that returns fixed turns.
private final class FakeDiarizer: SpeakerDiarizer, @unchecked Sendable {
    var turns: [SpeakerTurn]
    var error: Error?
    private(set) var calls = 0

    init(turns: [SpeakerTurn], error: Error? = nil) {
        self.turns = turns
        self.error = error
    }

    func isDownloaded() async -> Bool { true }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        calls += 1
        if let error { throw error }
        return turns
    }
}

/// Speaker separation: the overlap rule, labels, the stage wiring with a
/// fake diarizer, and the real FluidAudio diarizer on the fixture (skips
/// when its model is not on disk).
@MainActor
final class DiarizationTests: XCTestCase {

    private func segment(_ text: String, _ start: Double, _ end: Double, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(text: text, start: start, end: end, speaker: speaker)
    }

    // MARK: - Pure Rules

    func testEachSegmentTakesTheSpeakerItOverlapsMost() {
        let turns = [
            SpeakerTurn(speaker: "A", start: 0, end: 2.0),
            SpeakerTurn(speaker: "B", start: 2.0, end: 5.0),
        ]
        let segments = [segment("one", 0.2, 1.8), segment("two", 1.5, 4.0), segment("three", 6.0, 7.0)]
        let labelled = DiarizationService.assign(turns: turns, to: segments)
        XCTAssertEqual(labelled.map(\.speaker), ["A", "B", "B"], "the last segment takes the nearest turn")
    }

    func testRenumberingFollowsFirstAppearance() {
        let raw = [segment("a", 0, 1, speaker: "7"), segment("b", 1, 2, speaker: "3"), segment("c", 2, 3, speaker: "7")]
        let labelled = DiarizationService.renumber(raw)
        XCTAssertEqual(labelled.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(DiarizationService.speakers(in: labelled), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(
            DiarizationService.labelledText(labelled),
            "Speaker 1: a\n\nSpeaker 2: b\n\nSpeaker 1: c"
        )
    }

    func testCloudSpeakerLabelsSkipTheLocalDiarizer() async {
        let fake = FakeDiarizer(turns: [])
        let service = DiarizationService(diarizer: fake)
        let outcome = await service.assignSpeakers(
            segments: [segment("hi", 0, 1, speaker: "speaker_0"), segment("yo", 1, 2, speaker: "speaker_1")],
            recording: []
        )
        XCTAssertEqual(outcome.speakers, ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(fake.calls, 0)
    }

    func testDiarizerFailureKeepsTheTranscript() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let service = DiarizationService(diarizer: FakeDiarizer(turns: [], error: Boom()))
        let segments = [segment("hello", 0, 1)]
        let outcome = await service.assignSpeakers(segments: segments, recording: [0])
        XCTAssertEqual(outcome.segments, segments)
        XCTAssertEqual(outcome.speakers, [])
        XCTAssertEqual(outcome.warning, "Speaker separation failed: boom")
    }

    // MARK: - Stage Wiring

    func testStageLabelsSpeakersWhenTheModeAsks() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let fixture = try ASRFixture.samples()
        let half = ASRFixture.seconds(fixture) / 2
        env.services.transcription.diarization = DiarizationService(diarizer: FakeDiarizer(turns: [
            SpeakerTurn(speaker: "x", start: 0, end: half),
            SpeakerTurn(speaker: "y", start: half, end: ASRFixture.seconds(fixture)),
        ]))
        let session = env.session(samples: fixture, mode: Mode(name: "Meeting", diarize: true))
        _ = try await TranscribeStage(services: env.services).run(session)

        XCTAssertFalse(session.segments.isEmpty)
        XCTAssertTrue(session.segments.allSatisfy { $0.speaker != nil })
        XCTAssertEqual(session.speakers.first, "Speaker 1")
        if session.speakers.count > 1 {
            XCTAssertTrue(session.text.hasPrefix("Speaker 1: "), session.text)
        }
        XCTAssertTrue(session.rawTranscript.lowercased().contains("hello"))
    }

    // MARK: - Real Diarizer

    /// Creating this file on the test machine lets the test fetch the
    /// small diarizer model (about 14 MB) once.
    private static let downloadMarker = "/tmp/parrot-allow-diarizer-download"

    func testFluidDiarizerFindsASpeakerInTheFixture() async throws {
        let diarizer = FluidSpeakerDiarizer()
        if !(await diarizer.isDownloaded()), FileManager.default.fileExists(atPath: Self.downloadMarker) {
            try await diarizer.download { _ in }
        }
        let available = await diarizer.isDownloaded()
        try XCTSkipUnless(available, "diarizer model not on disk")

        let fixture = try ASRFixture.samples()
        let started = Date()
        let turns = try await diarizer.diarize(fixture)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(turns.count, 1, "at least one speaker turn")
        XCTAssertTrue(turns.allSatisfy { !$0.speaker.isEmpty && $0.end > $0.start })
        let size = ModelFiles.diskSize(of: FluidSpeakerDiarizer.cacheDirectory)
        print("[Diarization] \(turns.count) turns \(turns.map { "\($0.speaker) \(String(format: "%.2f-%.2f", $0.start, $0.end))" }) in \(String(format: "%.2f", seconds))s; model \(size / 1_000_000) MB at \(FluidSpeakerDiarizer.cacheDirectory.path)")

        // Through the stage: the fixture's segments come back labelled.
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let session = env.session(samples: fixture, mode: Mode(name: "Meeting", diarize: true))
        _ = try await TranscribeStage(services: env.services).run(session)
        XCTAssertGreaterThanOrEqual(session.segments.filter { $0.speaker != nil }.count, 1)
        XCTAssertEqual(session.speakers.first, "Speaker 1")
        print("[Diarization] stage segments: \(session.segments.map { "\($0.speaker ?? "-"): \($0.text)" }), speakers \(session.speakers)")
    }
}
