import AVFoundation
import XCTest

@testable import Parrot

/// End-to-end tests against real local backends. Each test skips itself when
/// its backend (a running Ollama server, the cached Parakeet model) is not
/// available, so the suite still passes on a clean machine.
final class OllamaIntegrationTests: XCTestCase {

    private static let baseURL = "http://localhost:11434/v1"

    private func installedModels() async -> [String] {
        (try? await OllamaAPI.listModels(baseURL: Self.baseURL)) ?? []
    }

    /// Picks a model capable of instruction-following for the meaning-preserving
    /// refinement test. Very small models (e.g. 0.5b) rewrite rather than clean,
    /// so prefer a known-capable one; skip if only tiny models are installed.
    private func capableModel(from models: [String]) -> String? {
        let preferred = ["llama3.2:3b", "qwen2.5:3b", "llama3.1:8b", "mistral", "ornith:35b"]
        if let match = preferred.first(where: { p in models.contains { $0.hasPrefix(p) } }) {
            return models.first { $0.hasPrefix(match) }
        }
        // Fall back to any model that is not obviously sub-1B.
        return models.first { !$0.contains("0.5b") && !$0.contains("0.5B") }
    }

    func testListModelsReturnsInstalledModels() async throws {
        let models = await installedModels()
        try XCTSkipIf(models.isEmpty, "Ollama not running or no models installed")
        XCTAssertFalse(models[0].isEmpty)
    }

    /// Full refinement path: raw dictation through the OpenAI-compatible wire
    /// to a real local model and back, verifying meaning is preserved.
    func testRefineEndToEndAgainstOllama() async throws {
        let models = await installedModels()
        try XCTSkipIf(models.isEmpty, "Ollama not running or no models installed")
        let model = try XCTUnwrap(
            capableModel(from: models),
            "No instruction-capable model installed (pull e.g. llama3.2:3b)"
        )

        var client = OpenAICompatibleClient(baseURL: Self.baseURL, apiKey: nil)
        client.timeoutInterval = 300

        let raw = "um so basically i think we should uh meet at too pm on thursday to discuss the new api design you now"
        let refined = try await client.refine(
            raw,
            system: RefinementService.systemPrompt(directive: nil),
            model: model
        ).lowercased()

        XCTAssertFalse(refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Meaning preserved: the day and the topic should survive the cleanup.
        // Check several content anchors rather than one brittle word.
        let anchors = ["thursday", "api", "design", "meet"]
        let survived = anchors.filter { refined.contains($0) }
        XCTAssertGreaterThanOrEqual(
            survived.count, 2,
            "refined text lost too much content (\(survived) survived): \(refined)"
        )
    }

    /// A missing model must surface Ollama's decoded error message, which is
    /// what triggers the raw-transcript fallback in the pipeline.
    func testUnknownModelSurfacesDecodedProviderError() async throws {
        let models = await installedModels()
        try XCTSkipIf(models.isEmpty, "Ollama not running or no models installed")

        let client = OpenAICompatibleClient(baseURL: Self.baseURL, apiKey: nil)
        do {
            _ = try await client.refine("hello", system: "test", model: "parrot-no-such-model")
            XCTFail("Expected a provider error")
        } catch let RefinementError.providerError(statusCode, message) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// An unreachable server must throw (URLError), exercising the same
    /// failure route the pipeline converts into paste-raw plus error toast.
    func testUnreachableServerThrows() async {
        var client = OpenAICompatibleClient(baseURL: "http://localhost:59999/v1", apiKey: nil)
        client.timeoutInterval = 5
        do {
            _ = try await client.refine("hello", system: "test", model: "any")
            XCTFail("Expected a connection error")
        } catch {
            // URLError (connection refused) is expected.
        }
    }
}

// MARK: - Parakeet

final class ParakeetIntegrationTests: XCTestCase {

    /// Fully offline speech-to-text: transcribes a committed 16kHz WAV fixture
    /// of the spoken phrase "Hello world, this is a Parrot transcription test."
    /// with the cached Parakeet model. No network, no API key.
    func testOfflineTranscriptionWithParakeet() async throws {
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")
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
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: cacheDir.path),
            "Parakeet model not cached; run the app once to download it"
        )

        let engine = TranscriptionEngine()
        try await engine.prepareModel()

        var entry = VocabularyEntry(original: "git hub", replacement: "GitHub")
        entry.isEnabled = true
        await engine.configureVocabulary(entries: [entry], enabled: true)
        XCTAssertTrue(engine.vocabularyBoostingActive, "boosting did not activate")

        await engine.configureVocabulary(entries: [entry], enabled: false)
        XCTAssertFalse(engine.vocabularyBoostingActive)
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
