import FluidAudio
import Foundation

/// Voice activity detection for silence removal and the short-clip gate,
/// on FluidAudio's Silero VAD model. [ASR]
///
/// The model loads in the background at launch (when either feature is on)
/// and on demand after that; a second request waits for the load already
/// running. Callers treat every error as "no answer" and keep the audio.
@MainActor
final class VoiceActivityService {

    /// Speech probability above which a frame counts as speech. Lower than
    /// FluidAudio's default so quiet words are kept: a kept silence costs
    /// little, a cut word is lost.
    nonisolated static let threshold: Float = 0.5

    /// Speech regions are padded so word edges survive the cut. FluidAudio
    /// asserts the padding is no longer than the shortest speech region.
    nonisolated static let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.2,
        minSilenceDuration: 0.5,
        maxSpeechDuration: 14,
        speechPadding: 0.2
    )

    /// Where FluidAudio keeps the Silero model once downloaded.
    nonisolated static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/silero-vad", isDirectory: true)
    }

    private var manager: VadManager?
    private var loading: Task<VadManager, Error>?

    init() {}

    /// True once the detector is in memory.
    var isReady: Bool { manager != nil }

    func start(services: AppServices) {
        if let transcription = services.settings?.transcription,
           !transcription.silenceRemoval, !transcription.shortClipGate {
            return
        }
        warmUp()
    }

    /// Loads the detector in the background. Failures are logged; the next
    /// use tries again.
    func warmUp() {
        Task {
            do {
                _ = try await loadedManager()
            } catch {
                diagLog("[Parrot:VAD] Model load failed: \(error)")
            }
        }
    }

    /// Loads the detector now, downloading it if needed.
    func prepare() async throws {
        _ = try await loadedManager()
    }

    /// Speech regions in 16 kHz sample indices, padded, sorted.
    func speechRegions(in samples: [Float]) async throws -> [Range<Int>] {
        let manager = try await loadedManager()
        let segments = try await manager.segmentSpeech(samples, config: Self.segmentation)
        let rate = VadManager.sampleRate
        return segments
            .map { $0.startSample(sampleRate: rate)..<$0.endSample(sampleRate: rate) }
            .filter { !$0.isEmpty }
    }

    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task {
            try await VadManager(config: VadConfig(defaultThreshold: Self.threshold))
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        manager = loaded
        diagLog("[Parrot:VAD] Silero VAD ready")
        return loaded
    }
}
