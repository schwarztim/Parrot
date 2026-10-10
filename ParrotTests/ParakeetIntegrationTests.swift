import AVFoundation
import XCTest

@testable import Parrot

/// End-to-end tests against the cached Parakeet model. Each test skips
/// itself when the model is not cached, so the suite still passes on a
/// clean machine.
final class ParakeetIntegrationTests: XCTestCase {

    /// Fully offline speech-to-text: transcribes a committed 16kHz WAV fixture
    /// of the spoken phrase "Hello world, this is a Parrot transcription test."
    /// with the cached Parakeet model. No network, no API key.
    func testOfflineTranscriptionWithParakeet() async throws {
        let cacheDir = TranscriptionEngine.modelCacheDirectory
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: cacheDir.path),
            "Parakeet model not cached; run the app once to download it"
        )

        let samples = try Self.fixtureSamples()
        XCTAssertGreaterThan(samples.count, 16_000, "expected at least a second of audio")

        let engine = TranscriptionEngine()
        try await engine.prepareModel()
        let text = try await engine.transcribe(samples)

        // "Parrot" is deliberately not asserted: Parakeet hears the synthetic
        // voice's "Parrot transcription" as one fused word.
        XCTAssertTrue(text.lowercased().contains("hello world"), "unexpected transcription: \(text)")
        XCTAssertTrue(text.lowercased().contains("test"), "unexpected transcription: \(text)")
    }

    /// Proves the real vocabulary-boosting path: prepare the model, configure
    /// boosting with a term, and confirm it activated. Downloads the auxiliary
    /// CTC model (~110M) on first run. Self-skips when Parakeet is not cached.
    func testVocabularyBoostingConfiguresAgainstRealModels() async throws {
        let cacheDir = TranscriptionEngine.modelCacheDirectory
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: cacheDir.path),
            "Parakeet model not cached; run the app once to download it"
        )

        let engine = TranscriptionEngine()
        try await engine.prepareModel()

        var entry = VocabularyEntry(original: "git hub", replacement: "GitHub")
        entry.isEnabled = true
        await engine.configureVocabulary(entries: [entry], enabled: true)
        let activated = await engine.vocabularyBoostingActive
        XCTAssertTrue(activated, "boosting did not activate")

        // Transcribing with boosting on runs the CTC rescoring pass; an
        // unrelated term must leave the transcript intact.
        let boosted = try await engine.transcribe(Self.fixtureSamples())
        XCTAssertTrue(boosted.lowercased().contains("hello world"), "unexpected transcription: \(boosted)")

        await engine.configureVocabulary(entries: [entry], enabled: false)
        let stillActive = await engine.vocabularyBoostingActive
        XCTAssertFalse(stillActive)
    }

    /// Loads the bundled WAV fixture as 16kHz mono Float32 samples, the same
    /// shape AudioRecorder produces.
    private static func fixtureSamples() throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "hello-parrot", withExtension: "wav", subdirectory: "Resources"),
            "hello-parrot.wav fixture missing from test bundle"
        )

        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)

        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
