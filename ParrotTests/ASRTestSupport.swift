import AVFoundation
import XCTest

@testable import Parrot

/// The committed speech fixture, "Hello world, this is a Parrot
/// transcription test.", as 16 kHz mono Float32 like AudioRecorder makes.
enum ASRFixture {

    static func samples() throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "hello-parrot", withExtension: "wav", subdirectory: "Resources"),
            "hello-parrot.wav fixture missing from test bundle"
        )
        let file = try AVAudioFile(forReading: url)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// The fixture with `seconds` of digital silence before and after.
    static func padded(seconds: Double) throws -> [Float] {
        let zeros = [Float](repeating: 0, count: Int(seconds * 16_000))
        return zeros + (try samples()) + zeros
    }

    static func zeros(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// True when the Parakeet V3 model is cached, so a test may load it.
    static func parakeetCached() async -> Bool {
        await TranscriptionEngine().isDownloaded()
    }

    static func seconds(_ samples: [Float]) -> Double {
        Double(samples.count) / 16_000
    }
}

/// Isolated settings and services for ASR tests: a unique defaults suite,
/// an in-memory secret store, a temporary vocabulary file, and toasts
/// captured instead of shown.
@MainActor
final class ASRTestEnvironment {
    let suiteName = "parrot.tests.asr.\(UUID().uuidString)"
    let vocabularyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("parrot-asr-vocab-\(UUID().uuidString).json")
    let settings: AppSettings
    let services: AppServices
    private(set) var toasts: [String] = []

    init() {
        settings = AppSettings(
            store: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            secrets: InMemorySecretStore()
        )
        services = AppServices(vocabulary: VocabularyManager(storageURL: vocabularyURL))
        services.settings = settings
        services.showTransientError = { [weak self] message in
            self?.toasts.append(message)
        }
    }

    /// A session that never reaches delivery: file source, no live mic.
    func session(samples: [Float], mode: Mode? = nil) -> DictationSession {
        let session = DictationSession(
            trigger: .menu, mode: mode, source: .file(URL(fileURLWithPath: "/tmp/parrot-asr-test.wav"))
        )
        session.samples = samples
        return session
    }

    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: vocabularyURL)
    }
}
