import AppKit
import AVFoundation
import Combine
import Foundation
import Observation
import SwiftUI

// MARK: - Debug Logging

/// Diagnostic logging is OFF by default and must never contain transcript
/// content. Enable with `defaults write com.parrot.dev parrot.debugLogging -bool YES`.
/// The log lives under Application Support with owner-only permissions, not in
/// world-readable /tmp.
private let diagLoggingEnabled = UserDefaults.standard.bool(forKey: "parrot.debugLogging")

private let diagLogURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parrot", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("diag.log")
}()

func diagLog(_ message: String) {
    guard diagLoggingEnabled else { return }
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = diagLogURL.path
    if FileManager.default.fileExists(atPath: path) {
        if let handle = try? FileHandle(forWritingTo: diagLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    } else {
        FileManager.default.createFile(
            atPath: path, contents: data,
            attributes: [.posixPermissions: 0o600]
        )
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
    case accessibility = 3
    case modelDownload = 4
    case tryIt = 5
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
///
/// Main-actor isolated: every property is UI state. Heavy work (model load,
/// transcription, refinement, network) runs inside actors or nonisolated
/// async functions, and the tasks that await it resume on the main actor.
@MainActor
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
            isDefault: true
        ),
        Mode(
            name: "Code",
            description: "Optimized for programming terminology"
        ),
    ] {
        didSet { modeManager?.replaceAll(modes) }
    }
    var currentMode: Mode?

    // MARK: - Vocabulary

    /// The vocabulary list, owned and persisted by `vocabularyManager`. Views
    /// edit it here; every change is saved and applies to the next dictation.
    var vocabularyEntries: [VocabularyEntry] {
        get { vocabularyManager.entries }
        set { vocabularyManager.replaceAll(newValue) }
    }

    // MARK: - Settings (inline, for views that bind directly)

    var recordingWindowStyle: RecordingWindowStyle = .classic
    var toggleRecordingHotkey: HotkeyBinding = .defaultHotkey
    var cancelRecordingHotkey: HotkeyBinding?
    var pushToTalkHotkey: HotkeyBinding?
    var enhanceRecordingHotkey: HotkeyBinding?
    var launchAtLogin: Bool = false

    // Enhance mode
    var isEnhanceMode: Bool = false

    /// Destination context captured at hotkey-down, used to make refinement
    /// aware of where the text is going.
    var capturedContext: DictationContext?

    /// Short label of the detected destination for the recording overlay,
    /// e.g. "Mail (Subject)". Nil when destination-aware refinement is off.
    var destinationLabel: String?

    /// Mode actually used for the in-flight dictation (auto-selected per app, or
    /// the user's current mode). Transient; never mutates the user's selection.
    private var activeDictationMode: Mode?

    /// Set by the Home refinement nudge to request the main window switch to
    /// the Configuration tab. MainWindow observes and resets it.
    var requestConfigurationTab: Bool = false

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
    var accessibilityPermissionGranted: Bool = false
    var isDownloadingModel: Bool = false
    var modelDownloadProgress: Double = 0.0

    // MARK: - Subsystem References

    private(set) var audioRecorder: AudioRecorder?
    private(set) var transcriptionEngine: TranscriptionEngine?
    private(set) var hotkeyManager: HotkeyManager?
    private(set) var textInserter: TextInserter?
    let vocabularyManager: VocabularyManager
    private(set) var modeManager: ModeManager?
    private(set) var permissionsManager: PermissionsManager?
    private(set) var historyStore: HistoryStore?

    /// Settings supplying transcription/refinement provider configuration.
    /// Wired at launch by ParrotApp.
    var settings: AppSettings?

    // MARK: - Initialization

    init(vocabularyManager: VocabularyManager = VocabularyManager()) {
        self.vocabularyManager = vocabularyManager
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
            permissions.refreshPermissions()
            microphonePermissionGranted = permissions.microphoneGranted
            inputMonitoringPermissionGranted = permissions.inputMonitoringGranted
            accessibilityPermissionGranted = permissions.accessibilityGranted
            if permissions.microphoneGranted {
                microphoneStatus = .connected
            }
        }
    }

    /// Creates the AudioRecorder early (before full setup) so the onboarding
    /// microphone step can show a live input level meter.
    func initAudioRecorder() {
        guard audioRecorder == nil else { return }
        audioRecorder = AudioRecorder()
        diagLog("[Parrot:Onboarding] Early AudioRecorder created")
    }

    /// Guards `beginModelPreparation` against launching more than one download.
    private var modelPreparationStarted = false

    /// Downloads and loads the Parakeet model in the background, wiring
    /// progress into the observable state. Idempotent: safe to call from the
    /// onboarding Welcome step (to start early) and again from setup.
    func beginModelPreparation() {
        guard !modelPreparationStarted else { return }
        modelPreparationStarted = true

        let engine = transcriptionEngine ?? TranscriptionEngine()
        transcriptionEngine = engine

        diagLog("[Parrot:Model] Starting model download/load task...")
        // Inherits the main actor: the download, load and prewarm run inside
        // the engine actor, and every line between awaits is back on main.
        Task { [weak self] in
            do {
                try await engine.prepareModel { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        currentStatus = .downloading(progress)
                        modelDownloadProgress = progress
                        isDownloadingModel = progress < 1.0
                        if let i = availableModels.firstIndex(where: { $0.name == "Parakeet V3" }) {
                            availableModels[i].downloadProgress = progress
                        }
                    }
                }

                try await engine.prewarm()
                diagLog("[Parrot:Model] Pre-warm complete, model READY")

                // Configure vocabulary boosting once the model is ready.
                await engine.configureVocabulary(
                    entries: self?.vocabularyEntries ?? [],
                    enabled: self?.settings?.vocabularyBoostingEnabled ?? false
                )

                guard let self else { return }
                if case .downloading = currentStatus {
                    currentStatus = .idle
                }
                isDownloadingModel = false
                if let i = availableModels.firstIndex(where: { $0.name == "Parakeet V3" }) {
                    availableModels[i].isDownloaded = true
                    availableModels[i].downloadProgress = 1.0
                }
            } catch {
                diagLog("[Parrot:Model] FAILED: \(error)")
                guard let self else { return }
                // Allow a retry after a failed attempt.
                modelPreparationStarted = false
                currentStatus = .error("Model setup failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                isDownloadingModel = false
            }
        }
    }

    // MARK: - Permission Health

    /// A missing permission surfaced in the menu bar health section.
    struct PermissionWarning: Identifiable {
        let id: String
        let message: String
        let pane: PermissionsManager.PermissionPane
    }

    /// Permissions that are missing right now, for the menu bar health rows.
    /// Empty when everything needed is granted (a healthy surface is silent).
    var permissionWarnings: [PermissionWarning] {
        var warnings: [PermissionWarning] = []
        if !microphonePermissionGranted {
            warnings.append(.init(id: "mic", message: "Microphone off: dictation cannot record", pane: .microphone))
        }
        if !inputMonitoringPermissionGranted {
            warnings.append(.init(id: "input", message: "Hotkey off: grant Input Monitoring", pane: .inputMonitoring))
        }
        if !accessibilityPermissionGranted {
            warnings.append(.init(id: "ax", message: "Auto-paste off: grant Accessibility", pane: .accessibility))
        }
        return warnings
    }

    /// Re-reads permission states from the OS. Call when the app reactivates so
    /// grants (or revocations) made in System Settings are reflected.
    @MainActor
    func refreshPermissionHealth() {
        guard let permissions = permissionsManager else { return }
        permissions.refreshPermissions()
        microphonePermissionGranted = permissions.microphoneGranted
        inputMonitoringPermissionGranted = permissions.inputMonitoringGranted
        accessibilityPermissionGranted = permissions.accessibilityGranted
        microphoneStatus = permissions.microphoneGranted ? .connected : microphoneStatus
    }

    /// Opens System Settings to the given privacy pane.
    func openPermissionSettings(_ pane: PermissionsManager.PermissionPane) {
        permissionsManager?.openSystemPreferences(for: pane)
    }

    /// Reconfigures ASR vocabulary boosting after a vocabulary edit or a toggle
    /// change. Reads the live UI entries so boosting reflects what the user
    /// sees. Fire-and-forget; failures are handled inside the engine.
    func refreshVocabularyBoosting() {
        guard let engine = transcriptionEngine else { return }
        let entries = vocabularyEntries
        let enabled = settings?.vocabularyBoostingEnabled ?? false
        Task {
            await engine.configureVocabulary(entries: entries, enabled: enabled)
        }
    }

    // MARK: - Onboarding Mic Level Meter

    /// Starts mic level monitoring for the onboarding microphone step. Accessing
    /// the audio input triggers the microphone TCC prompt via the audio
    /// subsystem, which is reliable on self-signed builds (unlike
    /// AVCaptureDevice.requestAccess). Also refreshes the granted flag.
    func startOnboardingMicMonitoring() {
        initAudioRecorder()
        // Opening the input triggers the mic permission prompt; bring the
        // wizard forward so the dialog can appear. Only onboarding does this.
        NSApp.activate(ignoringOtherApps: true)
        startInputMonitoring()
        Task { @MainActor in
            guard let permissions = permissionsManager else { return }
            // Poll briefly for the grant to land after the prompt.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let granted = permissions.checkMicrophonePermission()
                if granted {
                    microphonePermissionGranted = true
                    microphoneStatus = .connected
                    break
                }
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

    /// Guards against running full subsystem initialization more than once.
    /// `setup()` is invoked both from the onboarding model step and from the
    /// main window's onAppear; without this guard subsystems init twice.
    private var didSetup = false

    /// Async implementation of subsystem initialization.
    func setupAsync() async {
        guard !didSetup else { return }
        didSetup = true

        // Permissions
        let permissions = PermissionsManager()
        self.permissionsManager = permissions
        permissions.refreshPermissions()

        diagLog("[Parrot:Setup] Mic preflight: \(permissions.microphoneGranted)")
        diagLog("[Parrot:Setup] Accessibility: \(permissions.accessibilityGranted)")

        microphonePermissionGranted = permissions.microphoneGranted
        inputMonitoringPermissionGranted = permissions.inputMonitoringGranted
        accessibilityPermissionGranted = permissions.accessibilityGranted

        // Don't use AVCaptureDevice.requestAccess — it hangs for self-signed apps.
        // Instead, directly try AVAudioEngine which triggers the mic prompt via the
        // audio subsystem. The com.apple.security.device.audio-input entitlement
        // combined with NSMicrophoneUsageDescription in Info.plist handles the rest.
        microphonePermissionGranted = permissions.microphoneGranted
        microphoneStatus = permissions.microphoneGranted ? .connected : .permissionNotDetermined

        // Audio recorder (reuse the one created early for the onboarding mic
        // level meter, if present).
        let recorder = audioRecorder ?? AudioRecorder()
        self.audioRecorder = recorder
        diagLog("[Parrot:Setup] AudioRecorder ready")

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

        // Begin (or continue) model download. Idempotent: if the download was
        // already kicked off early from the onboarding Welcome step, this is a
        // no-op and the model is likely ready or nearly so.
        beginModelPreparation()

        // Text inserter
        self.textInserter = TextInserter()

        // History store (searchable local dictation history).
        self.historyStore = try? HistoryStore(databaseURL: HistoryStore.defaultURL())
        if let days = settings?.historyRetentionDays, days > 0 {
            try? historyStore?.pruneOlderThan(days: days)
        }

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

        // Re-check Accessibility for status only. The onboarding Accessibility
        // step owns requesting it; the pipeline must never ambush the user by
        // opening System Settings on its own. Paste degrades gracefully to
        // clipboard-only when this is missing (see TextInserter).
        let accessOK = permissions.checkAccessibilityPermission()
        accessibilityPermissionGranted = accessOK
        diagLog("[Parrot:Setup] Accessibility check: \(accessOK)")

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

        // Apply the saved binding before listening, so a custom hotkey works
        // as soon as setup finishes (including the onboarding Try it step)
        // instead of after the main window's delayed sync.
        if let settings { syncHotkeys(from: settings) }

        diagLog("[Parrot:Setup] Starting HotkeyManager")
        hotkey.start()

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

        // Capture the destination NOW, while the target app is still frontmost,
        // and warm the refinement provider. Both cost zero perceived latency
        // because they run before the user finishes speaking.
        captureDestinationContext()
        if let settings { RefinementService.warmUpIfLocal(settings: settings) }

        // Pause level monitoring before recording to avoid engine conflicts.
        pauseLevelMeter()

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

            RecordingOverlayPanel.show(appState: self)

            diagLog("[Parrot:AppState] Recording STARTED")
        } catch {
            currentStatus = .error("Recording failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            diagLog("[Parrot:AppState] Recording FAILED: \(error)")
            // Resume level monitoring since recording failed.
            resumeLevelMeterIfVisible()
        }
    }

    /// Captures the frontmost app and focused field. Always runs (it is cheap,
    /// bounded by a 0.1s AX timeout, and reads nothing from secure fields) so
    /// history logging and per-app auto-mode have the bundle id even when
    /// destination-aware refinement is off. Only the overlay label is gated on
    /// the setting; RefinementService independently gates prompt context.
    private func captureDestinationContext() {
        let context = ContextSnapshotter.capture()
        capturedContext = context
        destinationLabel = (settings?.destinationAwareRefinement == true) ? context.displayLabel : nil

        // Resolve the effective mode for this dictation: an app-assigned mode
        // wins, otherwise the user's current mode. Applied transiently so the
        // user's selection is never mutated.
        activeDictationMode = modeManager?.mode(forBundleID: context.bundleID) ?? currentMode
        diagLog("[Parrot:AppState] Destination: \(context.displayLabel ?? "unknown"), secure=\(context.isSecureField), mode=\(activeDictationMode?.name ?? "-")")
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
            RecordingOverlayPanel.hide()
            recordingState = .idle
            currentStatus = .idle
            resumeLevelMeterIfVisible()
            return
        }

        // Minimum ~0.3s of audio needed for reliable transcription.
        guard durationSec >= 0.3 else {
            diagLog("[Parrot:AppState] Recording too short (\(String(format: "%.1f", durationSec))s) — skipping transcription")
            RecordingOverlayPanel.hide()
            recordingState = .idle
            currentStatus = .idle
            resumeLevelMeterIfVisible()
            return
        }

        currentStatus = .processing

        // Warn if the recording hit the length cap and audio was dropped,
        // rather than silently truncating.
        if recorder.didReachCapacity {
            showTransientError("Recording reached the 2 minute limit; the end may be cut off.")
        }

        let forceRefinement = isEnhanceMode

        // Inherits the main actor. Transcription, refinement and the paste
        // await engines and nonisolated network code, then resume here, so
        // every read and write of AppState below happens on main.
        Task { [weak self] in
            guard let self else { return }

            do {
                var text = try await self.transcribe(samples)
                let rawTranscript = text

                // Apply vocabulary replacements.
                text = self.vocabularyManager.apply(to: text)

                // Refine via the configured LLM provider. Any failure falls
                // back to the raw transcript; dictation is never lost.
                if let settings = self.settings, settings.refinementEnabled || forceRefinement {
                    do {
                        text = try await RefinementService.refine(
                            text,
                            modePrompt: (self.activeDictationMode ?? self.currentMode)?.refinementPrompt,
                            context: self.capturedContext,
                            settings: settings
                        )
                    } catch {
                        diagLog("[Parrot:AppState] Refinement FAILED, pasting raw transcript: \(error)")
                        self.showTransientError(
                            "Refinement failed, pasted raw transcript. \(error.localizedDescription)"
                        )
                    }
                }

                diagLog("[Parrot:AppState] Transcription complete (\(text.count) chars)")

                // Snapshot values needed for history before the completion block
                // clears the transient context.
                let ctx = self.capturedContext
                let modeName = (self.activeDictationMode ?? self.currentMode)?.name

                self.lastTranscription = text
                self.recordingState = .idle
                self.currentStatus = .idle
                self.recordingDuration = 0
                self.waveformAmplitudes = []
                self.isEnhanceMode = false
                self.destinationLabel = nil
                self.activeDictationMode = nil
                self.capturedContext = nil
                self.settings?.successfulDictationCount += 1

                // Save to history (never for secure fields, never when disabled).
                if self.settings?.historyEnabled == true, ctx?.isSecureField != true {
                    try? self.historyStore?.insert(
                        rawTranscript: rawTranscript,
                        finalText: text,
                        appBundleID: ctx?.bundleID,
                        modeName: modeName
                    )
                }

                // Copy to the pasteboard and paste; the text stays on the
                // clipboard afterwards. If Accessibility is missing the paste
                // is skipped and the user is told, never a silent failure.
                let pasted = await TextInserter.insertText(text)
                diagLog("[Parrot:AppState] Text inserted, pasted=\(pasted)")
                RecordingOverlayPanel.hide()
                if !pasted {
                    self.showTransientError(
                        "Copied to clipboard. Grant Accessibility to auto-paste (press Cmd+V to paste now)."
                    )
                }

                // Resume the meter only if a view showing it is on screen.
                self.resumeLevelMeterIfVisible()

            } catch {
                diagLog("[Parrot:AppState] Transcription FAILED: \(error)")
                RecordingOverlayPanel.hide()
                self.recordingState = .idle
                self.currentStatus = .error("Transcription failed: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
                self.isEnhanceMode = false
                self.resumeLevelMeterIfVisible()
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
            showTransientError(
                "\(choice.displayName) is not configured, used on-device Parakeet instead."
            )
            return try await engine.transcribe(samples)
        }

        do {
            return try await cloud.transcribe(samples)
        } catch {
            diagLog("[Parrot:AppState] Cloud transcription FAILED: \(error)")
            guard isModelReady else { throw error }
            showTransientError(
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

    /// Toggles dictation: starts recording if idle, stops (and transcribes) if
    /// currently recording. Used by the `parrot://` URL scheme and tap-to-toggle.
    func toggleDictation() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Selects a mode by name (case-insensitive). Returns true if found.
    @discardableResult
    func selectMode(named name: String) -> Bool {
        guard let mode = modes.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else { return false }
        currentMode = mode
        modeManager?.selectMode(mode)
        return true
    }

    /// Cancels the current recording without transcribing.
    func cancelRecording() {
        guard isRecording, let recorder = audioRecorder else { return }
        _ = recorder.stopRecording()
        RecordingOverlayPanel.hide()
        isRecording = false
        recordingState = .idle
        currentStatus = .idle
        recordingDuration = 0
        waveformAmplitudes = []
        destinationLabel = nil
        activeDictationMode = nil
        capturedContext = nil
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

    /// True while a view that shows the input level meter (the Sound tab, the
    /// onboarding microphone step) is on screen. The meter, and so the mic,
    /// only runs while this is set; finishing a dictation never starts it.
    private var levelMeterVisible = false

    /// Called by a view that shows the input level meter when it appears.
    /// Updates `inputLevel` at ~20Hz. Does not record audio.
    func startInputMonitoring() {
        levelMeterVisible = true
        resumeLevelMeterIfVisible()
    }

    /// Called by a view that shows the input level meter when it disappears.
    func stopInputMonitoring() {
        levelMeterVisible = false
        pauseLevelMeter()
    }

    /// Restarts the meter after a recording only if a meter view is still on
    /// screen. Never activates Parrot.
    private func resumeLevelMeterIfVisible() {
        guard levelMeterVisible, !isRecording, levelPollTimer == nil else { return }
        guard let recorder = audioRecorder else {
            diagLog("[Parrot:AppState] startInputMonitoring: audioRecorder is nil!")
            return
        }
        diagLog("[Parrot:AppState] startInputMonitoring: calling recorder.startMonitoring()...")
        do {
            try recorder.startMonitoring()
            levelPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                // Scheduled on the main run loop, so it fires on main.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inputLevel = self.audioRecorder?.currentInputLevel ?? 0
                }
            }
            diagLog("[Parrot:AppState] Input monitoring started, polling at 20Hz")
        } catch {
            diagLog("[Parrot:AppState] startInputMonitoring FAILED: \(error)")
        }
    }

    /// Stops the meter engine and resets the level, keeping track of whether
    /// a meter view still wants it.
    private func pauseLevelMeter() {
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
