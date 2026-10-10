import Foundation
import Observation

/// Which voice models the library lists. Pure, so filters are testable.
/// [ASR]
struct VoiceModelFilter: Equatable {
    enum Location: String, CaseIterable, Identifiable {
        case any
        case onDevice
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return "All"
            case .onDevice: return "On device"
            case .cloud: return "Cloud"
            }
        }
    }

    var location: Location = .any
    /// A language code the model must accept, or nil for any.
    var language: String?
    var liveText = false
    var speakers = false
    var favoritesOnly = false
    var downloadedOnly = false
    var search = ""

    /// The models that pass, favorites first, otherwise in catalog order.
    /// Experimental models are hidden unless shown, except `keep` (a
    /// model a mode already uses).
    func apply(
        to models: [VoiceModelInfo],
        favorites: [String],
        downloaded: Set<String>,
        showExperimental: Bool,
        keep: String? = nil
    ) -> [VoiceModelInfo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let passed = models.filter { model in
            if model.isExperimental, !showExperimental, model.id != keep { return false }
            switch location {
            case .any: break
            case .onDevice: if !model.isOnDevice { return false }
            case .cloud: if model.isOnDevice { return false }
            }
            if liveText, !model.supportsRealtime { return false }
            if speakers, !model.supportsDiarization { return false }
            if favoritesOnly, !favorites.contains(model.id) { return false }
            if downloadedOnly, model.isOnDevice, !downloaded.contains(model.id) { return false }
            if downloadedOnly, !model.isOnDevice { return false }
            if let language, !LanguageCatalog.languages(for: model).contains(where: { $0.code == language }) {
                return false
            }
            if !query.isEmpty {
                let haystack = "\(model.name) \(model.detail) \(model.vendor)".lowercased()
                if !haystack.contains(query) { return false }
            }
            return true
        }
        let starred = passed.filter { favorites.contains($0.id) }
        return starred + passed.filter { !favorites.contains($0.id) }
    }
}

/// The voice model library: what is installed, where, how big, download
/// progress with cancel, delete, and favorites. [ASR]
///
/// Progress is published at most every 0.25 seconds. Downloads go through
/// the router, so a download started here and one started from the mode
/// editor are the same download.
@MainActor
@Observable
final class VoiceModelCatalog {

    enum InstallState: Equatable {
        /// A cloud model: nothing to download.
        case cloud
        case notDownloaded
        /// Fraction from 0 to 1.
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    /// What a downloaded model takes on disk and where.
    struct Storage: Equatable {
        var bytes: Int64
        var folder: URL
    }

    private(set) var states: [String: InstallState] = [:]
    private(set) var storage: [String: Storage] = [:]

    @ObservationIgnored private weak var router: TranscriptionRouter?
    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var lastPublished: [String: Date] = [:]
    /// Seconds between progress updates.
    @ObservationIgnored var progressInterval: TimeInterval = 0.25
    /// Where a model's files live. Tests point it at temporary folders.
    @ObservationIgnored var folderResolver: (VoiceModelInfo) -> URL? = VoiceModelCatalog.storageFolder(for:)

    init() {}

    func start(services: AppServices) {
        attach(router: services.transcription, settings: services.settings)
        Task { await refresh() }
    }

    /// Points the catalog at a router and settings (tests use their own).
    func attach(router: TranscriptionRouter, settings: AppSettings?) {
        self.router = router
        self.settings = settings
    }

    // MARK: - Reading

    func state(for model: VoiceModelInfo) -> InstallState {
        if !model.isOnDevice { return .cloud }
        return states[model.id] ?? .notDownloaded
    }

    var downloadedIDs: Set<String> {
        Set(states.compactMap { $0.value == .downloaded ? $0.key : nil })
    }

    /// Parakeet V3 is every dictation's fallback, so it stays installed.
    func canDelete(_ model: VoiceModelInfo) -> Bool {
        model.isOnDevice && model.id != VoiceModels.parakeetV3.id && state(for: model) == .downloaded
    }

    /// True when a cloud model has its vendor key (or settings) in place.
    func isConfigured(_ model: VoiceModelInfo) -> Bool {
        guard let router else { return false }
        return (try? router.engine(for: model, settings: settings)) != nil
    }

    // MARK: - Favorites

    func isFavorite(_ model: VoiceModelInfo) -> Bool {
        settings?.transcription.favorites.contains(model.id) ?? false
    }

    func toggleFavorite(_ model: VoiceModelInfo) {
        guard let transcription = settings?.transcription else { return }
        if let index = transcription.favorites.firstIndex(of: model.id) {
            transcription.favorites.remove(at: index)
        } else {
            transcription.favorites.append(model.id)
        }
    }

    // MARK: - Refresh

    /// Checks every on-device model's files and measures what is on disk.
    func refresh() async {
        guard let router else { return }
        for model in VoiceModels.all where model.isOnDevice {
            if case .downloading = states[model.id], router.isDownloading(model) { continue }
            let downloaded = await router.isDownloaded(model, settings: settings)
            states[model.id] = downloaded ? .downloaded : .notDownloaded
            if downloaded, let folder = folderResolver(model) {
                let bytes = await Task.detached { ModelFiles.diskSize(of: folder) }.value
                storage[model.id] = Storage(bytes: bytes, folder: folder)
            } else {
                storage[model.id] = nil
            }
        }
    }

    // MARK: - Download

    /// Starts a download. A download already running is left alone.
    func download(_ model: VoiceModelInfo) {
        guard model.isOnDevice, let router else { return }
        if case .downloading = state(for: model) { return }
        states[model.id] = .downloading(0)
        lastPublished[model.id] = nil
        let settings = self.settings
        Task {
            do {
                try await router.download(model, settings: settings) { [weak self] fraction in
                    Task { @MainActor in self?.publish(fraction, for: model.id) }
                }
                states[model.id] = .downloaded
                await refresh()
            } catch {
                if error is CancellationError || TranscriptionFailure.classify(error) == .cancelled {
                    diagLog("[Parrot:Catalog] Download of \(model.name) cancelled")
                    states[model.id] = .notDownloaded
                } else {
                    diagLog("[Parrot:Catalog] Download of \(model.name) failed: \(error.localizedDescription)")
                    states[model.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDownload(_ model: VoiceModelInfo) {
        router?.cancelDownload(model)
    }

    private func publish(_ fraction: Double, for id: String) {
        guard case .downloading = states[id] else { return }
        let now = Date()
        if let last = lastPublished[id], now.timeIntervalSince(last) < progressInterval, fraction < 1 { return }
        lastPublished[id] = now
        states[id] = .downloading(min(max(fraction, 0), 1))
    }

    // MARK: - Delete

    /// Unloads the model and removes its folder from disk.
    func delete(_ model: VoiceModelInfo) async throws {
        guard model.isOnDevice, model.id != VoiceModels.parakeetV3.id, let folder = folderResolver(model) else { return }
        await router?.unloadNow(model)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        diagLog("[Parrot:Catalog] Deleted \(model.name) at \(folder.path)")
        storage[model.id] = nil
        states[model.id] = .notDownloaded
        await refresh()
    }

    // MARK: - Locations

    /// The folder a model's files download into, or nil for cloud models.
    nonisolated static func storageFolder(for model: VoiceModelInfo) -> URL? {
        switch model.kind {
        case .parakeet(let version):
            return TranscriptionEngine(version: version).cacheDirectory
        case .whisperKit(let variant):
            return WhisperKitEngine.modelFolder(variant: variant)
        case .fluid(let kind):
            return FluidASREngine(kind: kind).cacheDirectory
        case .cloud, .vendor:
            return nil
        }
    }

    /// The folders that hold every on-device model, for the library footer.
    nonisolated static var storageRoots: [URL] {
        [FluidASREngine.modelsRoot, WhisperKitEngine.defaultDownloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")]
    }
}
