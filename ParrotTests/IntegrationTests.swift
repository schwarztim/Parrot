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

    func testListModelsReturnsInstalledModels() async throws {
        let models = await installedModels()
        try XCTSkipIf(models.isEmpty, "Ollama not running or no models installed")
        XCTAssertFalse(models[0].isEmpty)
    }

    /// Full refinement path: raw dictation through the OpenAI-compatible wire
    /// to a real local model and back.
    func testRefineEndToEndAgainstOllama() async throws {
        let models = await installedModels()
        try XCTSkipIf(models.isEmpty, "Ollama not running or no models installed")

        var client = OpenAICompatibleClient(baseURL: Self.baseURL, apiKey: nil)
        client.timeoutInterval = 300

        let raw = "um so basically i think we should uh meet at too pm on thursday to discuss the new api design you now"
        let refined = try await client.refine(
            raw,
            system: RefinementService.systemPrompt(directive: nil),
            model: models[0]
        )

        XCTAssertFalse(refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Meaning must be preserved through the cleanup.
        XCTAssertTrue(refined.lowercased().contains("thursday"), "refined text lost content: \(refined)")
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
