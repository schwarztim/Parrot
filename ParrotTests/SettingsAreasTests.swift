import Security
import XCTest

@testable import Parrot

/// Tests the per-area settings over an isolated UserDefaults suite and an
/// in-memory secret store, so neither `.standard` nor the real Keychain is
/// ever touched. Key names are string literals on purpose: they are the
/// names installed users already have saved.
final class SettingsAreasTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "ParrotSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings(secrets: SecretStore = InMemorySecretStore()) -> AppSettings {
        AppSettings(store: store, secrets: secrets)
    }

    /// Only this suite's own saved values, without global-domain entries.
    private var savedValues: NSDictionary {
        NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// Seeds the suite with the pre-split enhance-mode keys.
    private func seedLegacyEnhance() {
        defaults.set("https://example-res.openai.azure.com/openai/v1", forKey: "parrot.enhanceEndpoint")
        defaults.set("legacy-deployment", forKey: "parrot.enhanceModel")
    }

    // MARK: - Defaults

    func testDefaultsOnEmptySuite() {
        let settings = makeSettings()

        XCTAssertFalse(settings.general.launchAtLogin)
        XCTAssertFalse(settings.general.hasCompletedOnboarding)
        XCTAssertEqual(settings.general.successfulDictationCount, 0)
        XCTAssertFalse(settings.general.refinementNudgeDismissed)

        XCTAssertEqual(settings.recorder.recordingWindowStyle, .classic)

        XCTAssertEqual(settings.hotkeys.hotkeyBinding, .defaultHotkey)
        XCTAssertNil(settings.hotkeys.cancelHotkeyBinding)
        XCTAssertNil(settings.hotkeys.pushToTalkBinding)

        XCTAssertTrue(settings.audio.autoMicVolume)
        XCTAssertTrue(settings.audio.soundEffectsEnabled)
        XCTAssertEqual(settings.audio.soundEffectsVolume, 0.7)
        XCTAssertNil(settings.audio.selectedInputDeviceID)

        XCTAssertEqual(settings.transcription.transcriptionProvider, .parakeet)
        XCTAssertEqual(settings.transcription.openAITranscriptionModel, "whisper-1")
        XCTAssertEqual(settings.transcription.azureWhisperDeployment, "")
        XCTAssertTrue(settings.transcription.silenceRemoval)
        XCTAssertTrue(settings.transcription.shortClipGate)
        XCTAssertFalse(settings.transcription.dynamicNormalization)

        XCTAssertFalse(settings.refinement.refinementEnabled)
        XCTAssertEqual(settings.refinement.refinementProvider, .localServer)
        XCTAssertEqual(settings.refinement.localServerBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(settings.refinement.localServerModel, "")
        XCTAssertEqual(settings.refinement.openAIModel, "gpt-4o-mini")
        XCTAssertEqual(settings.refinement.azureOpenAIEndpoint, "")
        XCTAssertEqual(settings.refinement.azureOpenAIDeployment, "")
        XCTAssertEqual(settings.refinement.azureOpenAIAPIVersion, "2024-10-21")
        XCTAssertEqual(settings.refinement.anthropicModel, "claude-haiku-4-5")
        XCTAssertTrue(settings.refinement.destinationAwareRefinement)
        XCTAssertTrue(settings.refinement.contextLocalOnly)

        for id in ProviderID.allCases {
            XCTAssertEqual(settings.credentials.key(for: id), "", "\(id)")
        }
        XCTAssertTrue(settings.credentials.unreadable.isEmpty)

        XCTAssertTrue(settings.history.historyEnabled)
        XCTAssertEqual(settings.history.historyRetentionDays, 30)

        XCTAssertFalse(settings.vocabulary.vocabularyBoostingEnabled)

        XCTAssertFalse(settings.shouldShowRefinementNudge)
    }

    // MARK: - No Writes on Init

    func testInitWritesNothingOnEmptySuite() {
        let secrets = InMemorySecretStore()
        XCTAssertEqual(savedValues.count, 0)

        let settings = makeSettings(secrets: secrets)

        XCTAssertEqual(savedValues.count, 0, "init wrote \(savedValues)")
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertEqual(secrets.deleteCount, 0)

        // Control: the check above does see a write when one happens.
        settings.audio.autoMicVolume = false
        XCTAssertEqual(savedValues.count, 1)
    }

    // MARK: - Legacy Key Names

    func testExistingKeyNamesAreReadAndNotRewritten() throws {
        let cancel = HotkeyBinding(keyCode: 0x35, modifiers: [], displayName: "Escape")
        let toggle = HotkeyBinding(keyCode: 0x31, modifiers: [.option], displayName: "Option Space")
        let ptt = HotkeyBinding(keyCode: 0, modifiers: [], displayName: "Mouse 4", mouseButton: 3)

        defaults.set(true, forKey: "parrot.launchAtLogin")
        defaults.set(true, forKey: "parrot.hasCompletedOnboarding")
        defaults.set(7, forKey: "parrot.successfulDictationCount")
        defaults.set(true, forKey: "parrot.refinementNudgeDismissed")
        defaults.set(try encoded(RecordingWindowStyle.none), forKey: "parrot.recordingWindowStyle")
        defaults.set(try encoded(toggle), forKey: "parrot.hotkeyBinding")
        defaults.set(try encoded(cancel), forKey: "parrot.cancelHotkeyBinding")
        defaults.set(try encoded(ptt), forKey: "parrot.pushToTalkBinding")
        defaults.set(false, forKey: "parrot.autoMicVolume")
        defaults.set(false, forKey: "parrot.soundEffectsEnabled")
        defaults.set(0.25, forKey: "parrot.soundEffectsVolume")
        defaults.set("device-42", forKey: "parrot.selectedInputDeviceID")
        defaults.set("azureWhisper", forKey: "parrot.transcriptionProvider")
        defaults.set("gpt-4o-transcribe", forKey: "parrot.openAITranscriptionModel")
        defaults.set("whisper-dep", forKey: "parrot.azureWhisperDeployment")
        defaults.set(false, forKey: "parrot.silenceRemoval")
        defaults.set(true, forKey: "parrot.refinementEnabled")
        defaults.set("anthropic", forKey: "parrot.refinementProvider")
        defaults.set("http://localhost:1234/v1", forKey: "parrot.localServerBaseURL")
        defaults.set("llama3", forKey: "parrot.localServerModel")
        defaults.set("gpt-4o", forKey: "parrot.openAIModel")
        defaults.set("https://example-res.openai.azure.com", forKey: "parrot.azureOpenAIEndpoint")
        defaults.set("chat-dep", forKey: "parrot.azureOpenAIDeployment")
        defaults.set("2025-01-01", forKey: "parrot.azureOpenAIAPIVersion")
        defaults.set("claude-sonnet-5", forKey: "parrot.anthropicModel")
        defaults.set(false, forKey: "parrot.destinationAwareRefinement")
        defaults.set(false, forKey: "parrot.contextLocalOnly")
        defaults.set(false, forKey: "parrot.historyEnabled")
        defaults.set(0, forKey: "parrot.historyRetentionDays")
        defaults.set(true, forKey: "parrot.vocabularyBoostingEnabled")
        let before = savedValues

        let secrets = InMemorySecretStore(values: [
            "com.parrot.openai": "test-openai",
            "com.parrot.azure-openai": "test-azure",
            "com.parrot.anthropic": "test-anthropic",
            "com.parrot.local-server": "test-local",
            "com.parrot.groq": "test-groq",
        ])
        let settings = makeSettings(secrets: secrets)

        XCTAssertTrue(settings.general.launchAtLogin)
        XCTAssertTrue(settings.general.hasCompletedOnboarding)
        XCTAssertEqual(settings.general.successfulDictationCount, 7)
        XCTAssertTrue(settings.general.refinementNudgeDismissed)
        XCTAssertEqual(settings.recorder.recordingWindowStyle, RecordingWindowStyle.none)
        XCTAssertEqual(settings.hotkeys.hotkeyBinding, toggle)
        XCTAssertEqual(settings.hotkeys.cancelHotkeyBinding, cancel)
        XCTAssertEqual(settings.hotkeys.pushToTalkBinding, ptt)
        XCTAssertFalse(settings.audio.autoMicVolume)
        XCTAssertFalse(settings.audio.soundEffectsEnabled)
        XCTAssertEqual(settings.audio.soundEffectsVolume, 0.25)
        XCTAssertEqual(settings.audio.selectedInputDeviceID, "device-42")
        XCTAssertEqual(settings.transcription.transcriptionProvider, .azureWhisper)
        XCTAssertEqual(settings.transcription.openAITranscriptionModel, "gpt-4o-transcribe")
        XCTAssertEqual(settings.transcription.azureWhisperDeployment, "whisper-dep")
        XCTAssertFalse(settings.transcription.silenceRemoval)
        XCTAssertTrue(settings.refinement.refinementEnabled)
        XCTAssertEqual(settings.refinement.refinementProvider, .anthropic)
        XCTAssertEqual(settings.refinement.localServerBaseURL, "http://localhost:1234/v1")
        XCTAssertEqual(settings.refinement.localServerModel, "llama3")
        XCTAssertEqual(settings.refinement.openAIModel, "gpt-4o")
        XCTAssertEqual(settings.refinement.azureOpenAIEndpoint, "https://example-res.openai.azure.com")
        XCTAssertEqual(settings.refinement.azureOpenAIDeployment, "chat-dep")
        XCTAssertEqual(settings.refinement.azureOpenAIAPIVersion, "2025-01-01")
        XCTAssertEqual(settings.refinement.anthropicModel, "claude-sonnet-5")
        XCTAssertFalse(settings.refinement.destinationAwareRefinement)
        XCTAssertFalse(settings.refinement.contextLocalOnly)
        XCTAssertEqual(settings.credentials.key(for: .openAI), "test-openai")
        XCTAssertEqual(settings.credentials.key(for: .azureOpenAI), "test-azure")
        XCTAssertEqual(settings.credentials.key(for: .anthropic), "test-anthropic")
        XCTAssertEqual(settings.credentials.key(for: .localServer), "test-local")
        XCTAssertEqual(settings.credentials.key(for: .groq), "test-groq")
        XCTAssertFalse(settings.history.historyEnabled)
        XCTAssertEqual(settings.history.historyRetentionDays, 0)
        XCTAssertTrue(settings.vocabulary.vocabularyBoostingEnabled)

        XCTAssertEqual(savedValues, before, "init rewrote saved values")
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertEqual(secrets.deleteCount, 0)
    }

    // MARK: - Round Trips

    func testGeneralRoundTrip() {
        let settings = makeSettings()
        settings.general.launchAtLogin = true
        settings.general.hasCompletedOnboarding = true
        settings.general.successfulDictationCount = 5
        XCTAssertTrue(settings.shouldShowRefinementNudge)
        settings.general.refinementNudgeDismissed = true
        XCTAssertFalse(settings.shouldShowRefinementNudge)

        XCTAssertEqual(defaults.object(forKey: "parrot.successfulDictationCount") as? Int, 5)
        let reloaded = makeSettings()
        XCTAssertTrue(reloaded.general.launchAtLogin)
        XCTAssertTrue(reloaded.general.hasCompletedOnboarding)
        XCTAssertEqual(reloaded.general.successfulDictationCount, 5)
        XCTAssertTrue(reloaded.general.refinementNudgeDismissed)
    }

    func testRecorderRoundTrip() {
        makeSettings().recorder.recordingWindowStyle = .mini

        XCTAssertNotNil(defaults.data(forKey: "parrot.recordingWindowStyle"))
        XCTAssertEqual(makeSettings().recorder.recordingWindowStyle, .mini)
    }

    func testHotkeysRoundTrip() {
        let binding = HotkeyBinding(keyCode: 0x31, modifiers: [.command, .shift], displayName: "Cmd Shift Space")
        let settings = makeSettings()
        settings.hotkeys.hotkeyBinding = binding
        settings.hotkeys.cancelHotkeyBinding = binding
        settings.hotkeys.pushToTalkBinding = binding

        var reloaded = makeSettings()
        XCTAssertEqual(reloaded.hotkeys.hotkeyBinding, binding)
        XCTAssertEqual(reloaded.hotkeys.cancelHotkeyBinding, binding)
        XCTAssertEqual(reloaded.hotkeys.pushToTalkBinding, binding)

        // Clearing an optional binding removes its key.
        reloaded.hotkeys.cancelHotkeyBinding = nil
        XCTAssertNil(defaults.object(forKey: "parrot.cancelHotkeyBinding"))
        reloaded = makeSettings()
        XCTAssertNil(reloaded.hotkeys.cancelHotkeyBinding)
    }

    func testAudioRoundTrip() {
        let settings = makeSettings()
        settings.audio.autoMicVolume = false
        settings.audio.soundEffectsEnabled = false
        settings.audio.soundEffectsVolume = 0.4
        settings.audio.selectedInputDeviceID = "usb-mic"

        var reloaded = makeSettings()
        XCTAssertFalse(reloaded.audio.autoMicVolume)
        XCTAssertFalse(reloaded.audio.soundEffectsEnabled)
        XCTAssertEqual(reloaded.audio.soundEffectsVolume, 0.4)
        XCTAssertEqual(reloaded.audio.selectedInputDeviceID, "usb-mic")

        reloaded.audio.selectedInputDeviceID = nil
        reloaded = makeSettings()
        XCTAssertNil(reloaded.audio.selectedInputDeviceID)
    }

    func testTranscriptionRoundTrip() {
        let settings = makeSettings()
        settings.transcription.transcriptionProvider = .openAI
        settings.transcription.openAITranscriptionModel = "gpt-4o-mini-transcribe"
        settings.transcription.azureWhisperDeployment = "whisper"
        settings.transcription.silenceRemoval = false
        settings.transcription.shortClipGate = false
        settings.transcription.dynamicNormalization = true

        XCTAssertEqual(defaults.string(forKey: "parrot.transcriptionProvider"), "openAI")
        XCTAssertEqual(defaults.object(forKey: "parrot.asr.shortClipGate") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "parrot.asr.dynamicNormalization") as? Bool, true)
        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.transcription.transcriptionProvider, .openAI)
        XCTAssertEqual(reloaded.transcription.openAITranscriptionModel, "gpt-4o-mini-transcribe")
        XCTAssertEqual(reloaded.transcription.azureWhisperDeployment, "whisper")
        XCTAssertFalse(reloaded.transcription.silenceRemoval)
        XCTAssertFalse(reloaded.transcription.shortClipGate)
        XCTAssertTrue(reloaded.transcription.dynamicNormalization)
    }

    func testRefinementRoundTrip() {
        let settings = makeSettings()
        settings.refinement.refinementEnabled = true
        settings.refinement.refinementProvider = .azureOpenAI
        settings.refinement.localServerBaseURL = "http://127.0.0.1:8080/v1"
        settings.refinement.localServerModel = "qwen"
        settings.refinement.openAIModel = "gpt-4.1-mini"
        settings.refinement.azureOpenAIEndpoint = "https://example.openai.azure.com"
        settings.refinement.azureOpenAIDeployment = "dep"
        settings.refinement.azureOpenAIAPIVersion = "2025-02-01"
        settings.refinement.anthropicModel = "claude-opus-4-8"
        settings.refinement.destinationAwareRefinement = false
        settings.refinement.contextLocalOnly = false

        XCTAssertEqual(defaults.string(forKey: "parrot.refinementProvider"), "azureOpenAI")
        let reloaded = makeSettings()
        XCTAssertTrue(reloaded.refinement.refinementEnabled)
        XCTAssertEqual(reloaded.refinement.refinementProvider, .azureOpenAI)
        XCTAssertEqual(reloaded.refinement.localServerBaseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(reloaded.refinement.localServerModel, "qwen")
        XCTAssertEqual(reloaded.refinement.openAIModel, "gpt-4.1-mini")
        XCTAssertEqual(reloaded.refinement.azureOpenAIEndpoint, "https://example.openai.azure.com")
        XCTAssertEqual(reloaded.refinement.azureOpenAIDeployment, "dep")
        XCTAssertEqual(reloaded.refinement.azureOpenAIAPIVersion, "2025-02-01")
        XCTAssertEqual(reloaded.refinement.anthropicModel, "claude-opus-4-8")
        XCTAssertFalse(reloaded.refinement.destinationAwareRefinement)
        XCTAssertFalse(reloaded.refinement.contextLocalOnly)
    }

    func testCredentialsRoundTrip() {
        let secrets = InMemorySecretStore()
        let settings = makeSettings(secrets: secrets)

        settings.credentials.setKey("test-deepgram", for: .deepgram)
        settings.credentials.openAIKey = "test-openai"
        XCTAssertEqual(secrets.values["com.parrot.deepgram"], "test-deepgram")
        XCTAssertEqual(secrets.values["com.parrot.openai"], "test-openai")
        XCTAssertEqual(makeSettings(secrets: secrets).credentials.key(for: .openAI), "test-openai")

        // A field redraw with the same text writes nothing.
        let writes = secrets.writeCount
        settings.credentials.openAIKey = "test-openai"
        XCTAssertEqual(secrets.writeCount, writes)

        // Clearing the field and the Remove action are the explicit deletes.
        settings.credentials.openAIKey = ""
        settings.credentials.removeKey(for: .deepgram)
        XCTAssertNil(secrets.values["com.parrot.openai"])
        XCTAssertNil(secrets.values["com.parrot.deepgram"])
        XCTAssertEqual(secrets.deleteCount, 2)
        XCTAssertEqual(makeSettings(secrets: secrets).credentials.key(for: .openAI), "")

        // Keys never land in user defaults.
        XCTAssertEqual(savedValues.count, 0)
    }

    func testHistoryRoundTrip() {
        let settings = makeSettings()
        settings.history.historyEnabled = false
        settings.history.historyRetentionDays = 90

        let reloaded = makeSettings()
        XCTAssertFalse(reloaded.history.historyEnabled)
        XCTAssertEqual(reloaded.history.historyRetentionDays, 90)
    }

    func testVocabularyRoundTrip() {
        makeSettings().vocabulary.vocabularyBoostingEnabled = true

        XCTAssertEqual(defaults.object(forKey: "parrot.vocabularyBoostingEnabled") as? Bool, true)
        XCTAssertTrue(makeSettings().vocabulary.vocabularyBoostingEnabled)
    }

    // MARK: - Keychain Hazard

    /// A locked keychain (every read throws, as over ssh) must never cause a
    /// write or a delete: not on load, not in the legacy migration, and not
    /// when a key field redraws its empty text.
    func testLockedSecretStoreNeverWritesOrDeletes() {
        let saved = [
            "com.parrot.openai": "test-openai",
            "com.parrot.azure-openai": "test-azure",
            "com.parrot.anthropic": "test-anthropic",
            "com.parrot.local-server": "test-local",
            "com.parrot.enhance": "test-legacy",
        ]
        for seeded in [false, true] {
            defaults.removePersistentDomain(forName: suiteName)
            if seeded { seedLegacyEnhance() }
            let before = savedValues
            let secrets = InMemorySecretStore(
                values: saved,
                readError: KeychainError.readFailed(errSecInteractionNotAllowed)
            )

            let settings = makeSettings(secrets: secrets)

            XCTAssertEqual(secrets.writeCount, 0, "seeded: \(seeded)")
            XCTAssertEqual(secrets.deleteCount, 0, "seeded: \(seeded)")
            XCTAssertEqual(secrets.values, saved, "seeded: \(seeded)")
            XCTAssertEqual(savedValues, before, "seeded: \(seeded)")
            XCTAssertEqual(settings.credentials.unreadable, Set(ProviderID.allCases))
            XCTAssertEqual(settings.credentials.key(for: .openAI), "")
            XCTAssertEqual(settings.refinement.azureOpenAIEndpoint, "", "migration must wait for a readable key")

            // The key fields show "" and redraw with "": still nothing deleted.
            settings.credentials.openAIKey = ""
            settings.credentials.azureOpenAIKey = ""
            settings.credentials.anthropicKey = ""
            settings.credentials.localServerKey = ""
            XCTAssertEqual(secrets.deleteCount, 0, "seeded: \(seeded)")
            XCTAssertEqual(secrets.writeCount, 0, "seeded: \(seeded)")
        }
    }

    // MARK: - Legacy Enhance Migration

    func testLegacyEnhanceMigration() {
        seedLegacyEnhance()
        let secrets = InMemorySecretStore(values: ["com.parrot.enhance": "test-legacy"])

        let settings = makeSettings(secrets: secrets)

        XCTAssertEqual(settings.refinement.azureOpenAIEndpoint, "https://example-res.openai.azure.com")
        XCTAssertEqual(settings.refinement.azureOpenAIDeployment, "legacy-deployment")
        XCTAssertEqual(settings.refinement.refinementProvider, .azureOpenAI)
        XCTAssertEqual(settings.credentials.key(for: .azureOpenAI), "test-legacy")
        XCTAssertEqual(secrets.values["com.parrot.azure-openai"], "test-legacy")
        XCTAssertNil(secrets.values["com.parrot.enhance"])
        XCTAssertNil(defaults.object(forKey: "parrot.enhanceEndpoint"))
        XCTAssertNil(defaults.object(forKey: "parrot.enhanceModel"))

        // The migrated values were saved, and a second launch changes nothing.
        let after = savedValues
        let writes = secrets.writeCount
        let reloaded = makeSettings(secrets: secrets)
        XCTAssertEqual(reloaded.refinement.azureOpenAIEndpoint, "https://example-res.openai.azure.com")
        XCTAssertEqual(reloaded.refinement.azureOpenAIDeployment, "legacy-deployment")
        XCTAssertEqual(reloaded.refinement.refinementProvider, .azureOpenAI)
        XCTAssertEqual(reloaded.credentials.key(for: .azureOpenAI), "test-legacy")
        XCTAssertEqual(savedValues, after)
        XCTAssertEqual(secrets.writeCount, writes)
    }

    func testLegacyEnhanceMigrationSkipsWhenAzureEndpointIsSet() {
        seedLegacyEnhance()
        defaults.set("https://current.openai.azure.com", forKey: "parrot.azureOpenAIEndpoint")
        let secrets = InMemorySecretStore(values: ["com.parrot.enhance": "test-legacy"])

        let settings = makeSettings(secrets: secrets)

        XCTAssertEqual(settings.refinement.azureOpenAIEndpoint, "https://current.openai.azure.com")
        XCTAssertEqual(settings.refinement.refinementProvider, .localServer)
        XCTAssertEqual(secrets.values["com.parrot.enhance"], "test-legacy")
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertNotNil(defaults.object(forKey: "parrot.enhanceEndpoint"))
    }
}
