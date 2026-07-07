import XCTest

@testable import Parrot

/// Offline unit tests for the refinement layer: prompt scaffolding, provider
/// error decoding, Azure URL construction, and WAV encoding.
final class RefinementUnitTests: XCTestCase {

    // MARK: - System Prompt

    func testSystemPromptFallsBackToDefaultDirective() {
        for directive in [nil, "", "   \n"] {
            let prompt = RefinementService.systemPrompt(directive: directive)
            XCTAssertTrue(prompt.contains("You are a text filter"))
            XCTAssertTrue(prompt.contains("Correct speech-to-text errors"))
            XCTAssertTrue(prompt.contains("Return only the corrected text"))
        }
    }

    func testSystemPromptUsesCustomDirectiveInsideScaffold() {
        let prompt = RefinementService.systemPrompt(directive: "Format as a professional email.")
        XCTAssertTrue(prompt.contains("Format as a professional email."))
        // The anti-injection scaffold must survive a custom directive.
        XCTAssertTrue(prompt.contains("You are a text filter"))
        XCTAssertTrue(prompt.contains("Return only the corrected text"))
    }

    // MARK: - Error Decoding

    func testOpenAIStyleWrappedErrorDecodes() {
        let body = #"{"error": {"message": "model not found", "type": "not_found_error"}}"#
        let message = OpenAICompatibleClient.decodeErrorMessage(from: Data(body.utf8))
        XCTAssertEqual(message, "model not found")
    }

    func testOllamaFlatErrorDecodes() {
        let body = #"{"error": "model 'x' not found"}"#
        let message = OpenAICompatibleClient.decodeErrorMessage(from: Data(body.utf8))
        XCTAssertEqual(message, "model 'x' not found")
    }

    func testAnthropicErrorEnvelopeDecodes() {
        let body = #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}, "request_id": "req_123"}"#
        let message = AnthropicClient.decodeErrorMessage(from: Data(body.utf8))
        XCTAssertEqual(message, "invalid x-api-key")
    }

    func testAzureErrorEnvelopeDecodes() {
        let body = #"{"error": {"code": "401", "message": "Access denied due to invalid subscription key."}}"#
        let message = AzureOpenAIClient.decodeErrorMessage(from: Data(body.utf8))
        XCTAssertEqual(message, "Access denied due to invalid subscription key.")
    }

    func testUndecodableErrorFallsBackToRawBody() {
        let message = OpenAICompatibleClient.decodeErrorMessage(from: Data("plain text".utf8))
        XCTAssertEqual(message, "plain text")
    }

    // MARK: - Azure URL

    func testAzureChatURLConstruction() throws {
        let url = try AzureOpenAIClient.chatURL(
            endpoint: "https://my-resource.openai.azure.com/",
            deployment: "gpt-4o-mini",
            apiVersion: "2024-10-21"
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://my-resource.openai.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21"
        )
    }

    // MARK: - WAV Encoding

    func testWAVEncoderProducesValidHeader() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
        let data = WAVEncoder.encode(samples: samples)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")

        // Sample rate at offset 24, little-endian UInt32.
        let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)

        // Data chunk size at offset 40.
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: dataSize), UInt32(samples.count * 2))

        // Full-scale samples clamp to Int16 range.
        let pcm = data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        XCTAssertEqual(Int16(littleEndian: pcm[3]), Int16.max)
    }

    // MARK: - Mode Decoding Compatibility

    func testModeWithoutRefinementPromptStillDecodes() throws {
        // JSON shape written by versions before refinementPrompt existed.
        let legacy = """
            {"id": "\(UUID().uuidString)", "name": "Old", "description": "",
             "voiceModelVersion": "v3", "language": "auto", "isDefault": true}
            """
        let mode = try JSONDecoder().decode(Mode.self, from: Data(legacy.utf8))
        XCTAssertNil(mode.refinementPrompt)
    }
}
