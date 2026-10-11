import XCTest

@testable import Parrot

/// End-to-end tests against a real local Ollama server. Each test skips
/// itself when no server or model is available, so the suite still passes
/// on a clean machine.
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
