import XCTest

@testable import Parrot

/// On-device Whisper tiny through WhisperKit, directly and through the
/// router from a mode's voice model. Self-skips when the model folder is
/// not cached under ~/Documents/huggingface.
@MainActor
final class WhisperKitTests: XCTestCase {

    private let variant = "openai_whisper-tiny"

    func testTinyTranscribesDetectsAndTranslates() async throws {
        try XCTSkipUnless(WhisperKitEngine.isDownloaded(variant: variant), "Whisper tiny not cached")
        let samples = try ASRFixture.samples()
        let engine = WhisperKitEngine(variant: variant)
        try await engine.load()

        let detected = try await engine.transcribe(samples, options: TranscriptionOptions())
        XCTAssertTrue(detected.text.lowercased().contains("hello"), "unexpected transcript: \(detected.text)")
        XCTAssertEqual(detected.language, "en")
        XCTAssertFalse(detected.segments.isEmpty)

        let translated = try await engine.transcribe(
            samples, options: TranscriptionOptions(language: "en", translateToEnglish: true)
        )
        XCTAssertTrue(translated.text.lowercased().contains("hello"), "unexpected translation: \(translated.text)")
        print("[WhisperKit] detected \(detected.language ?? "?"): \(detected.text) | translate: \(translated.text)")

        await engine.unload()
        do {
            _ = try await engine.transcribe(samples, options: TranscriptionOptions())
            XCTFail("an unloaded engine must not transcribe")
        } catch {
            XCTAssertEqual(error as? TranscriptionFailure, .engineNotReady)
        }
    }

    func testModeVoiceModelRoutesToWhisper() async throws {
        try XCTSkipUnless(WhisperKitEngine.isDownloaded(variant: variant), "Whisper tiny not cached")
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let mode = Mode(name: "Whisper", voiceModelID: "whisper-tiny")
        let session = env.session(samples: try ASRFixture.samples(), mode: mode)

        let result = try await TranscribeStage(services: env.services).run(session)

        XCTAssertEqual(result, .continue)
        XCTAssertEqual(session.voiceModelID, "whisper-tiny")
        XCTAssertTrue(env.toasts.isEmpty, "no fallback expected: \(env.toasts)")
        XCTAssertTrue(session.text.lowercased().contains("hello"), "unexpected transcript: \(session.text)")
        XCTAssertEqual(session.language, "en")
    }
}
