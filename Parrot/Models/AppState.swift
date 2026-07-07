import AppKit
import AVFoundation
import Combine
import Foundation
import Observation
import SwiftUI

// MARK: - Debug Logging

private let diagLogPath = "/tmp/parrot-diag.log"

func diagLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: diagLogPath) {
            if let handle = FileHandle(forWritingAtPath: diagLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: diagLogPath, contents: data)
        }
    }
}

// MARK: - Enums

enum RecordingState: String {
    case idle
    case recording
    case processing
}

enum MicrophoneStatus: String {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case permissionDenied = "Permission Denied"
    case permissionNotDetermined = "Not Determined"
}

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case microphonePermission = 1
    case inputMonitoring = 2
    case modelDownload = 3
}

// MARK: - AppStatus

/// Represents the current operational status of the app.
enum AppStatus: Equatable {
    case idle
    case recording
    case processing
    case error(String)
    case downloading(Double)
}

// MARK: - Supporting Models

struct VoiceModel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var sizeDescription: String
    var sizeBytes: Int64
    var languageCount: Int
    var performanceDescription: String
    var isDownloaded: Bool
    var downloadProgress: Double

    init(
        id: UUID = UUID(),
        name: String,
        sizeDescription: String,
        sizeBytes: Int64,
        languageCount: Int,
        performanceDescription: String,
        isDownloaded: Bool = false,
        downloadProgress: Double = 0.0
    ) {
        self.id = id
        self.name = name
        self.sizeDescription = sizeDescription
        self.sizeBytes = sizeBytes
        self.languageCount = languageCount
        self.performanceDescription = performanceDescription
        self.isDownloaded = isDownloaded
        self.downloadProgress = downloadProgress
    }
}

struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var isDefault: Bool

    init(id: String = UUID().uuidString, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

// MARK: - App State

/// Central application state coordinator for the Parrot voice-to-text pipeline.
///
/// Manages all UI-observable state **and** coordinates subsystem lifecycle:
/// hotkey triggers -> audio capture -> transcription -> text insertion.
@Observable
final class AppState {

    // MARK: - Recording UI State

    var recordingState: RecordingState = .idle
    var microphoneStatus: MicrophoneStatus = .permissionNotDetermined
    var recordingDuration: TimeInterval = 0
    var waveformAmplitudes: [Float] = []

    // MARK: - Pipeline Status

    var currentStatus: AppStatus = .idle
    var isRecording: Bool = false
    var lastTranscription: String?
    var errorMessage: String?

    // MARK: - Modes (UI-level)

    /// UI-level mode list. Mirrored into ModeManager for persistence whenever
    /// a view mutates it.
    var modes: [Mode] = [
        Mode(
            name: "General",
            description: "Default dictation mode",
            voiceModelVersion: "v3",
            language: "auto",
            isDefault: true
        ),
        Mode(
            name: "Code",
            description: "Optimized for programming terminology",
            voiceModelVersion: "v3",
            language: "auto"
        ),
    ] {
        didSet { modeManager?.replaceAll(modes) }
    }
    var currentMode: Mode?

    // MARK: - Vocabulary

    var vocabularyEntries: [VocabularyEntry] = []

    // MARK: - Settings (inline, for views that bind directly)

    var recordingWindowStyle: RecordingWindowStyle = .classic
    var toggleRecordingHotkey: HotkeyBinding = .defaultHotkey
    var cancelRecordingHotkey: HotkeyBinding?
    var pushToTalkHotkey: HotkeyBinding?
    var enhanceRecordingHotkey: HotkeyBinding?
    var launchAtLogin: Bool = false

    // Enhance mode
    var isEnhanceMode: Bool = false

    // Sound / Level Monitoring
    var inputLevel: Float = 0
    private var levelPollTimer: Timer?
    var autoMicVolume: Bool = true
    var silenceRemoval: Bool = true
    var soundEffectsEnabled: Bool = true
    var soundEffectsVolume: Double = 0.7
    var availableInputDevices: [AudioInputDevice] = [
        AudioInputDevice(name: "MacBook Pro Microphone", isDefault: true),
    ]
    var selectedInputDeviceID: String?

    // Models
    var availableModels: [VoiceModel] = [
        VoiceModel(
            name: "Parakeet V3",
            sizeDescription: "~800 MB",
            sizeBytes: 800_000_000,
            languageCount: 25,
            performanceDescription: "~190x real-time on Apple Silicon"
        ),
    ]

    // Onboarding
    var hasCompletedOnboarding: Bool = false
    var currentOnboardingStep: OnboardingStep = .welcome
    var microphonePermissionGranted: Bool = false
    var inputMonitoringPermissionGranted: Bool = false
    var isDownloadingModel: Bool = false
    var modelDownloadProgress: Double = 0.0

    // MARK: - Subsystem References

    private(set) var audioRecorder: AudioRecorder?
    private(set) var transcriptionEngine: TranscriptionEngine?
    private(set) var hotkeyManager: HotkeyManager?
    private(set) var textInserter: TextInserter?
    private(set) var vocabularyManager: VocabularyManager?
    private(set) var modeManager: ModeManager?
    private(set) var permissionsManager: PermissionsManager?

    /// Settings supplying transcription/refinement provider configuration.
    /// Wired at launch by ParrotApp.
    var settings: AppSettings?

    // MARK: - Initialization

    init() {
        currentMode = modes.first(where: { $0.isDefault })
    }

    // MARK: - Computed Properties

    var selectedInputDevice: AudioInputDevice? {
        if let id = selectedInputDeviceID {
            return availableInputDevices.first(where: { $0.id == id })
        }
        return availableInputDevices.first(where: { $0.isDefault })
    }

    var isModelReady: Bool {
        availableModels.first?.isDownloaded ?? false
    }

    var modelStorageLocation: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.path ?? "~/Library/Application Support"
        return "\(appSupport)/Parrot/Models"
    }

    // MARK: - Early Initialization

    /// Initializes the PermissionsManager early (before full setup) so that
    /// onboarding can request permissions before the model download step.
    func initPermissionsManager() {
        guard permissionsManager == nil else { return }
        let permissions = PermissionsManager()
        self.permissionsManager = permissions
        Task { @MainActor in
            await permissions.refreshPermissions()
            microphonePermissionGranted = permissions.microphoneGranted
            inputMonitoringPermissionGranted = permissions.inputMonitoringGranted
            if permissions.microphoneGranted {
                microphoneStatus = .connected
            }
        }
    }

    // MARK: - Setup

    /// Initializes all app subsystems. Called once at app launch.
    ///
    /// Sets up audio recording, transcription engine (with model download),
    /// hotkey listener, text insertion, vocabulary, mode management, and
    /// permissions checking.
    func setup() {
        Task { @MainActor in
            await setupAsync()
        }
    }

    /// Async implementation of subsystem initialization.
    func setupAsync() async {
        // Permissions
        let permissions = PermissionsManager()
        self.permissionsManager = permissions
        await permissions.refreshPermissions()

        diagLog("[Parrot:Setup] Mic preflight: \(permissions.microphoneGranted)")
        diagLog("[Parrot:Setup] Accessibility: \(permissions.accessibilityGranted)")

        microphonePermissionGranted = permissions.microphoneGranted
        inputMonitoringPermissionGranted = permissions.inputMonitoringGranted

        // Don't use AVCaptureDevice.requestAccess — it hangs for self-signed apps.
        // Instead, directly try AVAudioEngine which triggers the mic prompt via the
        // audio subsystem. The com.apple.security.device.audio-input entitlement
        // combined with NSMicrophoneUsageDescription in Info.plist handles the rest.
        microphonePermissionGranted = permissions.microphoneGranted
        microphoneStatus = permissions.microphoneGranted ? .connected : .permissionNotDetermined

        // Audio recorder
        let recorder = AudioRecorder()
        self.audioRecorder = recorder
        diagLog("[Parrot:Setup] AudioRecorder created")

        // Populate available input devices.
        let devices = AudioRecorder.availableInputDevices()
        diagLog("[Parrot:Setup] Available input devices: \(devices.map { $0.name })")
        if !devices.isEmpty {
            availableInputDevices = devices.map { device in
                AudioInputDevice(
                    id: device.uid,
                    name: device.name,
                    isDefault: false
                )
            }
            // Mark the first device as default.
            if !availableInputDevices.isEmpty {
                availableInputDevices[0].isDefault = true
            }
        }

        // Transcription engine
        let engine = TranscriptionEngine()
        self.transcriptionEngine = engine

        // Begin model download / load in the background.
        diagLog("[Parrot:Setup] Starting model download/load task...")
        Task.detached { [weak self] in
            do {
                diagLog("[Parrot:Model] Calling prepareModel...")
                try await engine.prepareModel { progress in
                    diagLog("[Parrot:Model] Download progress: \(Int(progress * 100))%")
                    Task { @MainActor in
                        self?.currentStatus = .downloading(progress)
                        self?.modelDownloadProgress = progress
                        self?.isDownloadingModel = progress < 1.0

                        if let modelIndex = self?.availableModels.firstIndex(where: { $0.name == "Parakeet V3" }) {
                            self?.availableModels[modelIndex].downloadProgress = progress
                        }
                    }
                }

                diagLog("[Parrot:Model] Model loaded, pre-warming...")
                // Pre-warm model with a silent 1-second buffer.
                try await engine.prewarm()
                diagLog("[Parrot:Model] Pre-warm complete — model READY")

                await MainActor.run {
                    if case .downloading = self?.currentStatus {
                        self?.currentStatus = .idle
                    }
                    self?.isDownloadingModel = false

                    if let modelIndex = self?.availableModels.firstIndex(where: { $0.name == "Parakeet V3" }) {
                        self?.availableModels[modelIndex].isDownloaded = true
                        self?.availableModels[modelIndex].downloadProgress = 1.0
                    }
                    diagLog("[Parrot:Model] Status set to idle, isModelReady=\(self?.isModelReady ?? false)")
                }
            } catch {
                diagLog("[Parrot:Model] FAILED: \(error)")
                await MainActor.run {
                    self?.currentStatus = .error("Model setup failed: \(error.localizedDescription)")
                    self?.errorMessage = error.localizedDescription
                    self?.isDownloadingModel = false
                }
            }
        }

        // Text inserter
        self.textInserter = TextInserter()

        // Vocabulary manager
        let vocab = VocabularyManager()
        self.vocabularyManager = vocab
        self.vocabularyEntries = vocab.entries

        // Mode manager. On first launch, seed the persisted store with the
        // built-in UI modes; afterwards the persisted list is authoritative.
        let modeManager = ModeManager()
        if modeManager.isFreshInstall {
            modeManager.replaceAll(modes)
        }
        self.modes = modeManager.modes
        self.currentMode = modeManager.selectedMode
        self.modeManager = modeManager

        // Hotkey manager
        let hotkey = HotkeyManager()
        hotkey.onKeyDown = { [weak self] in
            diagLog("[Parrot:Hotkey] onKeyDown fired!")
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkey.onKeyUp = { [weak self] in
            diagLog("[Parrot:Hotkey] onKeyUp fired!")
            Task { @MainActor in
                self?.stopRecording()
            }
        }
        self.hotkeyManager = hotkey

        // Always re-check and request Accessibility on every launch.
        // Moving the app binary (e.g. ~/Applications → /Applications) can
        // invalidate the TCC entry even with a stable signing identity.
        let accessOK = permissions.checkAccessibilityPermission()
        diagLog("[Parrot:Setup] Accessibility check: \(accessOK)")
        if !accessOK {
            diagLog("[Parrot:Setup] Accessibility NOT granted — requesting + opening System Settings")
            permissions.requestAccessibilityAccess()
            permissions.openSystemPreferences(for: .accessibility)
        }

        // On macOS 15+, CGEventTap requires Input Monitoring (separate from Accessibility).
        // IMPORTANT: Always call ensureInputMonitoringAccess() regardless of what
        // CGPreflightListenEventAccess() returns, because the preflight API is
        // unreliable on macOS 15+ (returns true even when permission is NOT granted,
        // resulting in a "deaf" CGEventTap that silently drops all events).
        if #available(macOS 15.0, *) {
            diagLog("[Parrot:Setup] Input Monitoring: requesting via ensureInputMonitoringAccess()")
            permissions.ensureInputMonitoringAccess()
            diagLog("[Parrot:Setup] Input Monitoring granted: \(permissions.inputMonitoringGranted)")
        }

        // Wire up the deaf-tap callback so we can warn the user if the
        // CGEventTap was created but isn't receiving events.
        hotkey.onTapDeaf = { [weak self] in
            diagLog("[Parrot:Setup] CGEventTap is DEAF — Input Monitoring permission missing")
            diagLog("[Parrot:Setup] Opening System Settings > Input Monitoring")
            self?.permissionsManager?.openSystemPreferences(for: .inputMonitoring)
        }

        diagLog("[Parrot:Setup] Starting HotkeyManager")
        hotkey.start()

        // Verify audio engine works by starting the level monitor.
        diagLog("[Parrot:Setup] About to start input monitoring (audioRecorder=\(audioRecorder != nil))")
        startInputMonitoring()

        // Post-setup: log the full state so we can diagnose issues from the log alone.
        diagLog("[Parrot:Setup] === SETUP COMPLETE ===")
        diagLog("[Parrot:Setup] Model ready: \(isModelReady)")
        diagLog("[Parrot:Setup] Mic permission: \(microphonePermissionGranted)")
        diagLog("[Parrot:Setup] Accessibility: \(accessOK)")
        diagLog("[Parrot:Setup] Hotkey binding: keyCode=\(hotkey.binding.keyCode), modifierOnly=\(hotkey.binding.isModifierOnly), mouseButton=\(hotkey.binding.isMouseButton)")
        diagLog("[Parrot:Setup] Input devices: \(availableInputDevices.map { $0.name })")
    }

    // MARK: - Recording Pipeline

    /// Begins capturing audio from the microphone.
    func startRecording() {
        diagLog("[Parrot:AppState] startRecording called (status=\(currentStatus), recorder=\(audioRecorder != nil), modelReady=\(isModelReady))")

        // Only block if already recording or processing.
        // Allow start during model download — transcription will fail gracefully
        // with a clear error if the model isn't ready when recording stops.
        switch currentStatus {
        case .recording, .processing:
            diagLog("[Parrot:AppState] startRecording BLOCKED: status is \(currentStatus)")
            return
        case .error:
            errorMessage = nil
        case .idle, .downloading:
            break
        }

        guard let recorder = audioRecorder else {
            diagLog("[Parrot:AppState] startRecording BLOCKED: audioRecorder is nil")
            return
        }

        // Stop level monitoring before recording to avoid engine conflicts.
        stopInputMonitoring()

        do {
            try recorder.startRecording()
            isRecording = true
            recordingState = .recording
            currentStatus = .recording
            errorMessage = nil

            // Audio feedback so user knows recording started.
            if soundEffectsEnabled {
                NSSound(named: "Tink")?.play()
            }

            diagLog("[Parrot:AppState] Recording STARTED")
        } catch {
            currentStatus = .error("Recording failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            diagLog("[Parrot:AppState] Recording FAILED: \(error)")
            // Restart level monitoring since recording failed.
            startInputMonitoring()
        }
    }

    /// Stops recording, transcribes captured audio, and inserts the result as text.
    func stopRecording() {
        diagLog("[Parrot:AppState] stopRecording called (isRecording=\(isRecording), recorder=\(audioRecorder != nil))")
        guard isRecording, let recorder = audioRecorder else { return }

        let samples = recorder.stopRecording()
        isRecording = false
        recordingState = .processing

        // Audio feedback so user knows recording stopped.
        if soundEffectsEnabled {
            NSSound(named: "Pop")?.play()
        }

        let durationSec = Double(samples.count) / 16000.0
        diagLog("[Parrot:AppState] Captured \(samples.count) samples (\(String(format: "%.1f", durationSec))s)")

        guard !samples.isEmpty else {
            diagLog("[Parrot:AppState] No samples captured — skipping transcription")
            recordingState = .idle
            currentStatus = .idle
            startInputMonitoring()
            return
        }

        // Minimum ~0.3s of audio needed for reliable transcription.
        guard durationSec >= 0.3 else {
            diagLog("[Parrot:AppState] Recording too short (\(String(format: "%.1f", durationSec))s) — skipping transcription")
            recordingState = .idle
            currentStatus = .idle
            startInputMonitoring()
            return
        }

        currentStatus = .processing

        let forceRefinement = isEnhanceMode

        Task { [weak self] in
            guard let self else { return }

            do {
                var text = try await self.transcribe(samples)

                // Apply vocabulary replacements.
                if let vocab = self.vocabularyManager {
                    text = vocab.apply(to: text)
                }

                // Refine via the configured LLM provider. Any failure falls
                // back to the raw transcript; dictation is never lost.
                if let settings = self.settings, settings.refinementEnabled || forceRefinement {
                    do {
                        text = try await RefinementService.refine(
                            text,
                            modePrompt: self.currentMode?.refinementPrompt,
                            settings: settings
                        )
                    } catch {
                        diagLog("[Parrot:AppState] Refinement FAILED, pasting raw transcript: \(error)")
                        await self.showTransientError(
                            "Refinement failed, pasted raw transcript. \(error.localizedDescription)"
                        )
                    }
                }

                diagLog("[Parrot:AppState] Transcription result: \(text)")

                await MainActor.run {
                    self.lastTranscription = text
                    self.recordingState = .idle
                    self.currentStatus = .idle
                    self.recordingDuration = 0
                    self.waveformAmplitudes = []
                    self.isEnhanceMode = false
                }

                // Copy to the pasteboard and paste; the text stays on the
                // clipboard afterwards.
                await TextInserter.insertText(text)
                diagLog("[Parrot:AppState] Text inserted via Cmd+V")

                // Restart level monitoring.
                await MainActor.run { self.startInputMonitoring() }

            } catch {
                diagLog("[Parrot:AppState] Transcription FAILED: \(error)")
                await MainActor.run {
                    self.recordingState = .idle
                    self.currentStatus = .error("Transcription failed: \(error.localizedDescription)")
                    self.errorMessage = error.localizedDescription
                    self.isEnhanceMode = false
                    self.startInputMonitoring()
                }
            }
        }
    }

    // MARK: - Transcription Provider Selection

    /// Transcribes samples with the provider selected in settings.
    ///
    /// Cloud failures (or missing cloud configuration) fall back to the local
    /// Parakeet engine when it is ready, with a non-blocking error overlay,
    /// so dictation is never lost.
    private func transcribe(_ samples: [Float]) async throws -> String {
        guard let engine = transcriptionEngine else {
            throw TranscriptionError.engineNotReady
        }

        let choice = settings?.transcriptionProvider ?? .parakeet
        guard choice != .parakeet else {
            return try await engine.transcribe(samples)
        }

        guard let cloud = cloudTranscriber(for: choice) else {
            await showTransientError(
                "\(choice.displayName) is not configured, used on-device Parakeet instead."
            )
            return try await engine.transcribe(samples)
        }

        do {
            return try await cloud.transcribe(samples)
        } catch {
            diagLog("[Parrot:AppState] Cloud transcription FAILED: \(error)")
            guard isModelReady else { throw error }
            await showTransientError(
                "\(choice.displayName) failed, used on-device Parakeet instead. \(error.localizedDescription)"
            )
            return try await engine.transcribe(samples)
        }
    }

    /// Builds the cloud transcriber for the given choice, or nil when its
    /// settings are incomplete.
    private func cloudTranscriber(for choice: TranscriptionProviderChoice) -> TranscriptionProvider? {
        guard let settings else { return nil }
        switch choice {
        case .parakeet:
            return nil
        case .openAI:
            guard !settings.openAIKey.isEmpty, !settings.openAITranscriptionModel.isEmpty else { return nil }
            return OpenAITranscriber(apiKey: settings.openAIKey, model: settings.openAITranscriptionModel)
        case .azureWhisper:
            guard !settings.azureOpenAIEndpoint.isEmpty,
                  !settings.azureOpenAIKey.isEmpty,
                  !settings.azureWhisperDeployment.isEmpty
            else { return nil }
            return AzureWhisperTranscriber(
                endpoint: settings.azureOpenAIEndpoint,
                apiKey: settings.azureOpenAIKey,
                deployment: settings.azureWhisperDeployment,
                apiVersion: settings.azureOpenAIAPIVersion
            )
        }
    }

    // MARK: - Transient Errors

    /// Shows a non-blocking floating error toast and records the message.
    /// Does not change `currentStatus`; the pipeline continues normally.
    @MainActor
    private func showTransientError(_ message: String) {
        errorMessage = message
        ErrorToastPanel.show(message)
    }

    /// Begins recording with refinement forced on for this dictation, even if
    /// the global refinement toggle is off.
    func startEnhanceRecording() {
        isEnhanceMode = true
        startRecording()
    }

    /// Cancels the current recording without transcribing.
    func cancelRecording() {
        guard isRecording, let recorder = audioRecorder else { return }
        _ = recorder.stopRecording()
        isRecording = false
        recordingState = .idle
        currentStatus = .idle
        recordingDuration = 0
        waveformAmplitudes = []
    }
    // MARK: - Hotkey Sync

    /// Converts a UI-level `HotkeyBinding` to the CGEvent-level
    /// `GlobalHotkeyBinding` used by HotkeyManager, and activates it.
    func syncHotkeys(from settings: AppSettings) {
        guard let hotkey = hotkeyManager else { return }

        // Sync UI state from persisted settings
        toggleRecordingHotkey = settings.hotkeyBinding
        cancelRecordingHotkey = settings.cancelHotkeyBinding
        pushToTalkHotkey = settings.pushToTalkBinding

        let binding = settings.hotkeyBinding

        // Guard against broken bindings saved by the old keyCode:0 capture bug.
        // A keyboard binding with keyCode 0 and no mouse button is invalid
        // (unless it's intentionally "None"/empty).
        if binding.mouseButton == nil && binding.keyCode == 0 {
            hotkey.binding = .rightOption
        } else {
            hotkey.binding = Self.toGlobalBinding(binding)
        }
    }

    /// Converts a UI-level HotkeyBinding to the CGEvent-level GlobalHotkeyBinding.
    static func toGlobalBinding(_ binding: HotkeyBinding) -> HotkeyManager.GlobalHotkeyBinding {
        // Mouse button binding
        if let mouse = binding.mouseButton {
            return HotkeyManager.GlobalHotkeyBinding(
                keyCode: 0,
                modifierFlags: 0,
                isModifierOnly: false,
                isMouseButton: true,
                mouseButton: mouse
            )
        }

        let modifierKeyCodes: Set<UInt16> = [
            0x3A, 0x3D, // Left/Right Option
            0x37, 0x36, // Left/Right Command
            0x38, 0x3C, // Left/Right Shift
            0x3B, 0x3E, // Left/Right Control
        ]
        let isModOnly = modifierKeyCodes.contains(binding.keyCode)

        let flags: UInt64
        if isModOnly {
            flags = Self.modifierFlagForKeyCode(binding.keyCode)
        } else {
            flags = binding.cgEventFlags.rawValue
        }

        return HotkeyManager.GlobalHotkeyBinding(
            keyCode: Int(binding.keyCode),
            modifierFlags: flags,
            isModifierOnly: isModOnly
        )
    }

    private static func modifierFlagForKeyCode(_ keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 0x3A, 0x3D: return CGEventFlags.maskAlternate.rawValue
        case 0x37, 0x36: return CGEventFlags.maskCommand.rawValue
        case 0x38, 0x3C: return CGEventFlags.maskShift.rawValue
        case 0x3B, 0x3E: return CGEventFlags.maskControl.rawValue
        default: return 0
        }
    }

    // MARK: - Input Level Monitoring

    /// Starts monitoring the microphone input level for visualization.
    /// Updates `inputLevel` at ~20Hz. Does not record audio.
    func startInputMonitoring() {
        guard let recorder = audioRecorder else {
            diagLog("[Parrot:AppState] startInputMonitoring: audioRecorder is nil!")
            return
        }
        diagLog("[Parrot:AppState] startInputMonitoring: calling recorder.startMonitoring()...")
        do {
            try recorder.startMonitoring()
            levelPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.inputLevel = self.audioRecorder?.currentInputLevel ?? 0
            }
            diagLog("[Parrot:AppState] Input monitoring started, polling at 20Hz")
        } catch {
            diagLog("[Parrot:AppState] startInputMonitoring FAILED: \(error)")
        }
    }

    /// Stops monitoring and resets the input level.
    func stopInputMonitoring() {
        levelPollTimer?.invalidate()
        levelPollTimer = nil
        audioRecorder?.stopMonitoring()
        inputLevel = 0
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Transcription engine is not ready. Please wait for model download to complete."
        }
    }
}
