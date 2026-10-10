import Foundation
import Observation

/// Speech-to-text settings. [ASR]
@Observable
final class TranscriptionSettings {

    private enum Key {
        static let transcriptionProvider = "parrot.transcriptionProvider"
        static let openAITranscriptionModel = "parrot.openAITranscriptionModel"
        static let azureWhisperDeployment = "parrot.azureWhisperDeployment"
        static let silenceRemoval = "parrot.silenceRemoval"
        static let shortClipGate = "parrot.asr.shortClipGate"
        static let dynamicNormalization = "parrot.asr.dynamicNormalization"
        static let activeDuration = "parrot.asr.activeDuration"
    }

    var transcriptionProvider: TranscriptionProviderChoice {
        didSet { store.set(transcriptionProvider, forKey: Key.transcriptionProvider) }
    }

    var openAITranscriptionModel: String {
        didSet { store.set(openAITranscriptionModel, forKey: Key.openAITranscriptionModel) }
    }

    /// Azure Whisper deployment name. Uses the same resource endpoint, key,
    /// and API version as Azure OpenAI refinement.
    var azureWhisperDeployment: String {
        didSet { store.set(azureWhisperDeployment, forKey: Key.azureWhisperDeployment) }
    }

    /// Cut silence out of the recording before transcription (Silero VAD).
    var silenceRemoval: Bool {
        didSet { store.set(silenceRemoval, forKey: Key.silenceRemoval) }
    }

    /// Skip transcription of short clips in which no speech is detected.
    var shortClipGate: Bool {
        didSet { store.set(shortClipGate, forKey: Key.shortClipGate) }
    }

    /// Even out input loudness before transcription.
    var dynamicNormalization: Bool {
        didSet { store.set(dynamicNormalization, forKey: Key.dynamicNormalization) }
    }

    /// Seconds an on-device voice model stays loaded after its last use.
    /// Zero keeps it loaded.
    var activeDuration: TimeInterval {
        didSet { store.set(activeDuration, forKey: Key.activeDuration) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        transcriptionProvider = store.value(Key.transcriptionProvider, default: .parakeet)
        openAITranscriptionModel = store.string(Key.openAITranscriptionModel, default: "whisper-1")
        azureWhisperDeployment = store.string(Key.azureWhisperDeployment, default: "")
        silenceRemoval = store.bool(Key.silenceRemoval, default: true)
        shortClipGate = store.bool(Key.shortClipGate, default: true)
        dynamicNormalization = store.bool(Key.dynamicNormalization, default: false)
        activeDuration = store.double(Key.activeDuration, default: 60)
        self.store = store
    }
}
