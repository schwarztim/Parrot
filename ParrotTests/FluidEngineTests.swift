import XCTest

@testable import Parrot

/// Cohere, Canary, SenseVoice and Paraformer through the router. Their
/// models are large and not cached on the test machine, so each fixture
/// test skips unless the model is already on disk; nothing downloads here.
@MainActor
final class FluidEngineTests: XCTestCase {

    func testCatalogEntriesAndRouting() throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        for model in [VoiceModels.cohere, VoiceModels.canary, VoiceModels.senseVoice, VoiceModels.paraformer] {
            XCTAssertTrue(model.isOnDevice)
            XCTAssertGreaterThan(model.downloadBytes, 100_000_000, model.name)
            XCTAssertFalse(model.supportsRealtime, model.name)
            let engine = try env.services.transcription.engine(for: model, settings: env.settings)
            XCTAssertTrue(engine is FluidASREngine, model.name)
            XCTAssertTrue(
                (try env.services.transcription.engine(for: model, settings: env.settings)) === engine,
                "on-device engines are made once"
            )
        }
        XCTAssertEqual(LanguageCatalog.languages(for: VoiceModels.cohere).count, 14)
        XCTAssertEqual(LanguageCatalog.choices(for: VoiceModels.cohere).first?.code, "auto")
        XCTAssertEqual(LanguageCatalog.languages(for: VoiceModels.senseVoice).map(\.code).sorted(), ["en", "ja", "ko", "yue", "zh"])
        XCTAssertEqual(LanguageCatalog.choices(for: VoiceModels.paraformer).map(\.code), ["zh"])
        XCTAssertFalse(LanguageCatalog.choices(for: VoiceModels.canary).contains { $0.code == "auto" }, "Canary needs a fixed language")
        XCTAssertEqual(LanguageCatalog.defaultCode(for: VoiceModels.canary), "en")
        XCTAssertTrue(VoiceModels.canary.supportsTranslation)
    }

    func testCohereLanguageIdentificationFromProbeText() {
        XCTAssertEqual(CohereLanguageID.guess(text: "Bonjour, je voudrais réserver une table pour ce soir, s'il vous plaît."), "fr")
        XCTAssertEqual(CohereLanguageID.guess(text: "Guten Morgen, ich möchte heute Abend einen Tisch reservieren."), "de")
        XCTAssertEqual(CohereLanguageID.guess(text: "Hello, I would like to book a table for tonight, please."), "en")
        XCTAssertEqual(CohereLanguageID.guess(text: "今日はいい天気ですね。散歩に行きましょう。"), "ja")
        XCTAssertNil(CohereLanguageID.guess(text: "   "))
    }

    func testEachEngineTranscribesTheFixtureWhenItsModelIsCached() async throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let router = env.services.transcription
        var ran = 0
        for model in [VoiceModels.senseVoice, VoiceModels.paraformer, VoiceModels.canary, VoiceModels.cohere] {
            guard await router.isDownloaded(model, settings: env.settings) else { continue }
            let options = TranscriptionOptions(language: model.supportsAutoLanguage ? nil : LanguageCatalog.defaultCode(for: model))
            let output = try await router.transcribe(try ASRFixture.samples(), model: model, options: options, settings: env.settings)
            print("[FluidEngine] \(model.name): \(output.text) (\(output.language ?? "?"))")
            XCTAssertFalse(output.text.isEmpty, model.name)
            ran += 1
        }
        try XCTSkipIf(ran == 0, "no Cohere, Canary, SenseVoice or Paraformer model on disk")
    }
}
