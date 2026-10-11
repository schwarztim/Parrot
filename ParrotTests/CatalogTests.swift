import XCTest

@testable import Parrot

/// An engine whose download reports progress slowly and stops when
/// cancelled.
private actor SlowDownloadEngine: BatchTranscriptionEngine {
    private(set) var downloaded = false

    func isDownloaded() async -> Bool { downloaded }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        for step in 1...200 {
            try Task.checkCancellation()
            progress(Double(step) / 200)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        downloaded = true
    }

    func load() async throws {}
    func unload() async {}
    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptOutput {
        TranscriptOutput(text: "")
    }
}

/// The model library: filters, favorites and the experimental switch in
/// settings, real on-disk state, download progress with cancel, delete.
@MainActor
final class CatalogTests: XCTestCase {

    private var env: ASRTestEnvironment!
    private var folders: [URL] = []

    override func setUp() async throws {
        env = ASRTestEnvironment()
    }

    override func tearDown() async throws {
        env.tearDown()
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ models: [VoiceModelInfo]) -> [String] { models.map(\.id) }

    // MARK: - Filters

    func testLocationAndCapabilityFilters() {
        let all = VoiceModels.all
        var filter = VoiceModelFilter()

        filter.location = .onDevice
        let onDevice = filter.apply(to: all, favorites: [], downloaded: [], showExperimental: true)
        XCTAssertTrue(onDevice.allSatisfy(\.isOnDevice))
        XCTAssertTrue(ids(onDevice).contains("parakeet-v3"))

        filter.location = .cloud
        let cloud = filter.apply(to: all, favorites: [], downloaded: [], showExperimental: true)
        XCTAssertTrue(cloud.allSatisfy { !$0.isOnDevice })
        XCTAssertTrue(ids(cloud).contains("deepgram-nova-3"))

        filter = VoiceModelFilter()
        filter.liveText = true
        let live = filter.apply(to: all, favorites: [], downloaded: [], showExperimental: true)
        XCTAssertEqual(
            Set(ids(live)),
            ["parakeet-v3", "parakeet-v2", "deepgram-nova-3", "deepgram-nova-2", "deepgram-nova-2-medical", "elevenlabs-scribe-v2"]
        )

        filter = VoiceModelFilter()
        filter.speakers = true
        XCTAssertTrue(filter.apply(to: all, favorites: [], downloaded: [], showExperimental: true).allSatisfy(\.supportsDiarization))

        filter = VoiceModelFilter()
        filter.language = "ko"
        let korean = ids(filter.apply(to: all, favorites: [], downloaded: [], showExperimental: true))
        XCTAssertTrue(korean.contains("sensevoice-small"))
        XCTAssertTrue(korean.contains("cohere-transcribe"))
        XCTAssertFalse(korean.contains("parakeet-v3"), "Parakeet V3 is European languages only")
        XCTAssertFalse(korean.contains("whisper-tiny.en"))

        filter = VoiceModelFilter()
        filter.search = "groq"
        XCTAssertEqual(
            ids(filter.apply(to: all, favorites: [], downloaded: [], showExperimental: true)),
            ["groq-whisper-large-v3", "groq-whisper-large-v3-turbo"]
        )
    }

    func testExperimentalModelsHiddenUnlessShownOrInUse() {
        let filter = VoiceModelFilter()
        let hidden = ids(filter.apply(to: VoiceModels.all, favorites: [], downloaded: [], showExperimental: false))
        XCTAssertFalse(hidden.contains(VoiceModels.cohere.id))
        XCTAssertFalse(hidden.contains(VoiceModels.canary.id))
        XCTAssertTrue(hidden.contains(VoiceModels.senseVoice.id))

        let shown = ids(filter.apply(to: VoiceModels.all, favorites: [], downloaded: [], showExperimental: true))
        XCTAssertTrue(shown.contains(VoiceModels.cohere.id))

        let kept = ids(filter.apply(to: VoiceModels.all, favorites: [], downloaded: [], showExperimental: false, keep: VoiceModels.canary.id))
        XCTAssertTrue(kept.contains(VoiceModels.canary.id), "a mode's current model stays listed")
        XCTAssertFalse(kept.contains(VoiceModels.cohere.id))
    }

    func testFavoritesAndDownloadedFilters() {
        var filter = VoiceModelFilter()
        let favorites = ["deepgram-nova-3", "whisper-small"]
        let ordered = ids(filter.apply(to: VoiceModels.all, favorites: favorites, downloaded: [], showExperimental: false))
        XCTAssertEqual(Array(ordered.prefix(2)), ["whisper-small", "deepgram-nova-3"], "favorites first, in catalog order")

        filter.favoritesOnly = true
        XCTAssertEqual(Set(ids(filter.apply(to: VoiceModels.all, favorites: favorites, downloaded: [], showExperimental: false))), Set(favorites))

        filter = VoiceModelFilter()
        filter.downloadedOnly = true
        XCTAssertEqual(
            ids(filter.apply(to: VoiceModels.all, favorites: [], downloaded: ["parakeet-v3", "whisper-tiny"], showExperimental: false)),
            ["parakeet-v3", "whisper-tiny"]
        )
    }

    // MARK: - Settings

    func testFavoritesAndExperimentalPersist() {
        let catalog = VoiceModelCatalog()
        catalog.attach(router: env.services.transcription, settings: env.settings)
        XCTAssertFalse(env.settings.transcription.showExperimental, "experimental models are off by default")
        XCTAssertTrue(env.settings.transcription.favorites.isEmpty)

        catalog.toggleFavorite(VoiceModels.senseVoice)
        catalog.toggleFavorite(VoiceModels.deepgramNova3)
        catalog.toggleFavorite(VoiceModels.senseVoice)
        XCTAssertTrue(catalog.isFavorite(VoiceModels.deepgramNova3))
        XCTAssertFalse(catalog.isFavorite(VoiceModels.senseVoice))
        env.settings.transcription.showExperimental = true

        let defaults = UserDefaults(suiteName: env.suiteName)!
        XCTAssertNotNil(defaults.data(forKey: "parrot.asr.favorites"))
        XCTAssertEqual(defaults.object(forKey: "parrot.asr.showExperimental") as? Bool, true)

        let reloaded = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
        XCTAssertEqual(reloaded.transcription.favorites, ["deepgram-nova-3"])
        XCTAssertTrue(reloaded.transcription.showExperimental)
    }

    // MARK: - Disk State

    func testRefreshReportsCachedModelsWithTheirTrueSize() async throws {
        let catalog = VoiceModelCatalog()
        catalog.attach(router: env.services.transcription, settings: env.settings)
        await catalog.refresh()

        let tinyCached = WhisperKitEngine.isDownloaded(variant: "openai_whisper-tiny")
        try XCTSkipUnless(tinyCached, "Whisper tiny not cached")
        let tiny = try XCTUnwrap(VoiceModels.model(id: "whisper-tiny"))
        XCTAssertEqual(catalog.state(for: tiny), .downloaded)
        let storage = try XCTUnwrap(catalog.storage[tiny.id])
        XCTAssertEqual(storage.folder, WhisperKitEngine.modelFolder(variant: "openai_whisper-tiny"))
        XCTAssertGreaterThan(storage.bytes, 30_000_000)
        XCTAssertTrue(catalog.canDelete(tiny))
        XCTAssertFalse(catalog.canDelete(VoiceModels.parakeetV3), "the fallback model is never deleted")
        XCTAssertEqual(catalog.state(for: VoiceModels.deepgramNova3), .cloud)
        print("[Catalog] whisper-tiny \(storage.bytes / 1_000_000) MB at \(storage.folder.path); parakeet-v3 \(String(describing: catalog.storage[VoiceModels.parakeetV3.id]?.bytes))")
    }

    func testDeleteRemovesTheFolderAndResetsState() async throws {
        // Whisper Base is not cached; its folder here is a temporary stand-in,
        // so no real model is ever touched.
        let model = try XCTUnwrap(VoiceModels.model(id: "whisper-base"))
        try XCTSkipIf(WhisperKitEngine.isDownloaded(variant: "openai_whisper-base"), "a real Whisper Base is installed")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-catalog-\(UUID().uuidString)")
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 4_096).write(to: folder.appendingPathComponent("weights.bin"))

        let catalog = VoiceModelCatalog()
        catalog.attach(router: env.services.transcription, settings: env.settings)
        catalog.folderResolver = { $0.id == model.id ? folder : nil }
        try await catalog.delete(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(catalog.state(for: model), .notDownloaded)
        XCTAssertNil(catalog.storage[model.id])
    }

    func testDownloadProgressAndCancel() async throws {
        let engine = SlowDownloadEngine()
        let router = TranscriptionRouter(
            vocabulary: env.services.vocabulary, loadTimeout: 5, factory: { _, _ in engine }
        )
        let catalog = VoiceModelCatalog()
        catalog.progressInterval = 0
        catalog.attach(router: router, settings: env.settings)
        let model = VoiceModels.senseVoice

        catalog.download(model)
        var sawProgress = false
        for _ in 0..<200 {
            if case .downloading(let fraction) = catalog.state(for: model), fraction > 0 {
                sawProgress = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawProgress, "progress arrives while downloading")
        XCTAssertTrue(router.isDownloading(model))

        catalog.cancelDownload(model)
        for _ in 0..<200 where catalog.state(for: model) != .notDownloaded {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(catalog.state(for: model), .notDownloaded, "a cancelled download leaves the model not downloaded")
        XCTAssertFalse(router.isDownloading(model))
        let finished = await engine.downloaded
        XCTAssertFalse(finished)
    }
}
