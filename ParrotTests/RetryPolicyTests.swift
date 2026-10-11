import XCTest

@testable import Parrot

/// Retry policy (3 tries, 200 ms steps), error classification, and the
/// real TranscribeStage falling back from an unconfigured cloud provider to
/// on-device Parakeet.
@MainActor
final class RetryPolicyTests: XCTestCase {

    private struct Flaky: Error {}

    // MARK: - Policy

    func testRetryableFailuresRetryWithLinearBackoff() async throws {
        var sleeps: [TimeInterval] = []
        var attempts = 0

        let value = try await RetryPolicy.standard.run(sleep: { sleeps.append($0) }) { attempt -> String in
            attempts = attempt
            if attempt < 3 { throw URLError(.networkConnectionLost) }
            return "ok"
        }

        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, [0.2, 0.4])
    }

    func testGivesUpAfterThreeAttemptsWithTheLastFailure() async {
        var sleeps: [TimeInterval] = []
        var attempts = 0

        do {
            _ = try await RetryPolicy.standard.run(sleep: { sleeps.append($0) }) { attempt -> String in
                attempts = attempt
                throw CloudTranscriberError.providerError(statusCode: 503, message: "busy")
            }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .http(status: 503, message: "busy"))
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, [0.2, 0.4])
    }

    func testNonRetryableFailureStopsAtOnce() async {
        var sleeps: [TimeInterval] = []
        var attempts = 0

        do {
            _ = try await RetryPolicy.standard.run(sleep: { sleeps.append($0) }) { attempt -> String in
                attempts = attempt
                throw CloudTranscriberError.providerError(statusCode: 401, message: "bad key")
            }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .http(status: 401, message: "bad key"))
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(sleeps.isEmpty)
    }

    // MARK: - Classification

    func testClassification() {
        XCTAssertEqual(TranscriptionFailure.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(
            TranscriptionFailure.classify(URLError(.notConnectedToInternet)),
            .network(URLError(.notConnectedToInternet).localizedDescription)
        )
        XCTAssertEqual(TranscriptionFailure.classify(TranscriptionEngineError.notReady), .engineNotReady)
        XCTAssertEqual(TranscriptionFailure.classify(CancellationError()), .cancelled)
        if case .recognizer = TranscriptionFailure.classify(Flaky()) {} else {
            XCTFail("an unknown engine error should count as a recognizer failure")
        }
    }

    func testRetryableKinds() {
        XCTAssertTrue(TranscriptionFailure.timeout.isRetryable)
        XCTAssertTrue(TranscriptionFailure.network("down").isRetryable)
        XCTAssertTrue(TranscriptionFailure.recognizer("CoreML").isRetryable)
        XCTAssertTrue(TranscriptionFailure.http(status: 429, message: "").isRetryable)
        XCTAssertTrue(TranscriptionFailure.http(status: 500, message: "").isRetryable)
        XCTAssertFalse(TranscriptionFailure.http(status: 400, message: "").isRetryable)
        XCTAssertFalse(TranscriptionFailure.notConfigured("OpenAI").isRetryable)
        XCTAssertFalse(TranscriptionFailure.modelNotDownloaded("Whisper Small").isRetryable)
        XCTAssertFalse(TranscriptionFailure.loadTimedOut("Parakeet V3", 120).isRetryable)
        XCTAssertFalse(TranscriptionFailure.cancelled.isRetryable)
    }

    // MARK: - Stage

    /// OpenAI selected with no key: the stage falls back to Parakeet V3,
    /// toasts, records the model used and its timings.
    func testUnconfiguredCloudFallsBackToParakeet() async throws {
        let cached = await ASRFixture.parakeetCached()
        try XCTSkipUnless(cached, "Parakeet model not cached")
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        env.settings.transcription.transcriptionProvider = .openAI
        let session = env.session(samples: try ASRFixture.samples())

        let result = try await TranscribeStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
        XCTAssertTrue(session.text.lowercased().contains("hello"), "unexpected transcript: \(session.text)")
        XCTAssertEqual(session.voiceModelID, VoiceModels.parakeetV3.id)
        XCTAssertEqual(env.toasts, ["OpenAI (cloud) is not configured, used on-device Parakeet instead."])
        XCTAssertEqual(session.transcriptionAttempts, 2, "one failed cloud attempt, one local")
        XCTAssertNotNil(session.timings[TranscribeStage.TimingKey.load])
        XCTAssertGreaterThan(session.timings[TranscribeStage.TimingKey.recognition] ?? 0, 0)
        print(String(
            format: "[RetryPolicy] fallback load %.2fs, recognition %.2fs, transcript: %@",
            session.timings[TranscribeStage.TimingKey.load] ?? 0,
            session.timings[TranscribeStage.TimingKey.recognition] ?? 0,
            session.text
        ))
    }
}
