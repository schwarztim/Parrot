import XCTest

@testable import Parrot

/// The short-clip gate: a short clip with no speech ends the session
/// `.empty` before transcription; speech passes; detector trouble fails open.
@MainActor
final class ShortClipGateTests: XCTestCase {

    private var env: ASRTestEnvironment!

    override func setUp() async throws {
        env = ASRTestEnvironment()
        env.settings.transcription.shortClipGate = true
        env.settings.transcription.silenceRemoval = false
    }

    override func tearDown() async throws {
        env.tearDown()
        env = nil
    }

    func testRuleSkipsOnlyShortClipsWithoutSpeech() {
        XCTAssertTrue(ShortClipGate.shouldSkip(duration: 1, speechSamples: 0))
        XCTAssertFalse(ShortClipGate.shouldSkip(duration: 1, speechSamples: 4_000))
        XCTAssertFalse(ShortClipGate.shouldSkip(duration: ShortClipGate.maxDuration + 1, speechSamples: 0))
    }

    func testOneSecondOfSilenceIsSkipped() async throws {
        try await env.services.vad.prepare()
        let session = env.session(samples: ASRFixture.zeros(seconds: 1))

        let result = try await PreprocessAudioStage(services: env.services).run(session)

        XCTAssertEqual(result, .finish(.empty))
        XCTAssertEqual(session.speechSeconds, 0)
    }

    func testFixturePassesTheGate() async throws {
        try await env.services.vad.prepare()
        let session = env.session(samples: try ASRFixture.samples())

        let result = try await PreprocessAudioStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
        XCTAssertGreaterThan(session.speechSeconds ?? 0, 1.0)
        print(String(format: "[ShortClipGate] fixture speech %.2fs", session.speechSeconds ?? 0))
    }

    func testGateOffLetsSilenceThrough() async throws {
        try await env.services.vad.prepare()
        env.settings.transcription.shortClipGate = false
        let session = env.session(samples: ASRFixture.zeros(seconds: 1))

        let result = try await PreprocessAudioStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
    }

    /// The detector is not loaded (a fresh service): the gate fails open
    /// and transcription proceeds.
    func testDetectorNotReadyFailsOpen() async throws {
        XCTAssertFalse(env.services.vad.isReady)
        let session = env.session(samples: ASRFixture.zeros(seconds: 1))

        let result = try await PreprocessAudioStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
        XCTAssertNil(session.speechSeconds)
    }
}
