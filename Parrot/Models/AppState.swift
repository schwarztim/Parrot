import AppKit
import AVFoundation
import Combine
import Foundation
import Observation
import ServiceManagement
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

// MARK: - App State

/// Central application state for the Parrot voice-to-text app.
///
/// Holds the UI-observable state and creates the subsystems at setup. A
/// dictation itself runs in `DictationController` and the pipeline stages;
/// AppState forwards start, stop, cancel and toggle to the controller and
/// mirrors its progress into the status the views read.
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
    /// The selected mode. ModeManager is the source of truth once it exists,
    /// so every writer (hotkeys, URLs, the recorder, the mode list) and every
    /// reader see the same mode; `launchMode` only covers the moment before
    /// setup creates the manager.
    var currentMode: Mode? {
        get { modeManager?.selectedMode ?? launchMode }
        set {
            launchMode = newValue
            if let newValue, let modeManager, modeManager.selectedMode.id != newValue.id {
                modeManager.selectMode(newValue)
            }
        }
    }
    private var launchMode: Mode?

    // MARK: - Vocabulary

    /// The vocabulary list, owned and persisted by `vocabularyManager`. Views
    /// edit it here; every change is saved and applies to the next dictation.
    var vocabularyEntries: [VocabularyEntry] {
        get { vocabularyManager.entries }
        set { vocabularyManager.replaceAll(newValue) }
    }

    // MARK: - Settings (inline, for views that bind directly)

    // Saved settings live in the `AppSettings` areas. This binding is not
    // saved anywhere yet.
    var enhanceRecordingHotkey: HotkeyBinding?

    /// Whether Parrot is registered as a login item. The system is the source
    /// of truth: read with `refreshLaunchAtLogin()`, change with
    /// `setLaunchAtLogin(_:)`.
    private(set) var launchAtLogin: Bool = false

    // Enhance mode
    var isEnhanceMode: Bool = false

    /// Short label of the detected destination for the recording overlay,
    /// e.g. "Mail (Subject)". Nil when destination-aware refinement is off.
    var destinationLabel: String? { services.live.destinationLabel }

    /// The main window's selected tab. Views switch tabs with
    /// `navigation.request(_:)`.
    let navigation = NavigationModel()

    // Sound / Level Monitoring
    var inputLevel: Float = 0
    private var levelPollTimer: Timer?

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
    var currentOnboardingStep: OnboardingStep = .welcome
    var microphonePermissionGranted: Bool = false
    var inputMonitoringPermissionGranted: Bool = false
    var accessibilityPermissionGranted: Bool = false
    var isDownloadingModel: Bool = false
    var modelDownloadProgress: Double = 0.0

    // MARK: - Subsystem References

    /// Every service a dictation uses, handed to the pipeline stages.
    let services: AppServices
    /// Runs dictations. Every entry point (hotkey, URL, overlay) goes here.
    let controller: DictationController

    var audioRecorder: AudioRecorder? { services.audioRecorder }
    var transcriptionEngine: TranscriptionEngine? { services.transcription.engine }
    var hotkeyManager: HotkeyManager? { services.hotkeys.manager }
    var textInserter: TextInserter? { services.textInserter }
    let vocabularyManager: VocabularyManager
    var modeManager: ModeManager? { services.modes }
    var permissionsManager: PermissionsManager? { services.permissions }
    var historyStore: HistoryStore? { services.history }

    /// Settings supplying transcription/refinement provider configuration.
    /// Wired at launch by ParrotApp.
    var settings: AppSettings? {
        get { services.settings }
        set { services.settings = newValue }
    }

    // MARK: - Initialization

    init(vocabularyManager: VocabularyManager = VocabularyManager()) {
        self.vocabularyManager = vocabularyManager
        let services = AppServices(vocabulary: vocabularyManager)
        self.services = services
        self.controller = DictationController(services: services)
        currentMode = modes.first(where: { $0.isDefault })

        controller.delegate = self
        services.recorderUI = self
        services.showTransientError = { [weak self] message in
            self?.showTransientError(message)
        }
    }

    // MARK: - Computed Properties

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
        services.permissions = permissions
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
        services.audioRecorder = AudioRecorder()
        diagLog("[Parrot:Onboarding] Early AudioRecorder created")
    }

    /// Downloads and loads the Parakeet model in the background, wiring
    /// progress into the observable state. Idempotent: safe to call from the
    /// onboarding Welcome step (to start early) and again from setup.
    func beginModelPreparation() {
        services.transcription.prepare(settings: settings) { [weak self] event in
            guard let self else { return }
            switch event {
            case .progress(let progress):
                currentStatus = .downloading(progress)
                modelDownloadProgress = progress
                isDownloadingModel = progress < 1.0
                if let i = availableModels.firstIndex(where: { $0.name == "Parakeet V3" }) {
                    availableModels[i].downloadProgress = progress
                }
            case .ready:
                if case .downloading = currentStatus {
                    currentStatus = .idle
                }
                isDownloadingModel = false
                if let i = availableModels.firstIndex(where: { $0.name == "Parakeet V3" }) {
                    availableModels[i].isDownloaded = true
                    availableModels[i].downloadProgress = 1.0
                }
            case .failed(let error):
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
        let enabled = settings?.vocabulary.vocabularyBoostingEnabled ?? false
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
        services.permissions = permissions
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
        services.audioRecorder = recorder
        diagLog("[Parrot:Setup] AudioRecorder ready")

        // Begin (or continue) model download. Idempotent: if the download was
        // already kicked off early from the onboarding Welcome step, this is a
        // no-op and the model is likely ready or nearly so.
        beginModelPreparation()

        // Text inserter
        services.textInserter = TextInserter()

        // History store (searchable local dictation history).
        services.history = try? HistoryStore(databaseURL: HistoryStore.defaultURL())
        if let days = settings?.history.historyRetentionDays, days > 0 {
            _ = try? historyStore?.pruneOlderThan(days: days)
        }

        // Mode manager. On first launch, seed the persisted store with the
        // built-in UI modes; afterwards the persisted list is authoritative.
        let modeManager = ModeManager()
        if modeManager.isFreshInstall {
            modeManager.replaceAll(modes)
        }
        self.modes = modeManager.modes
        self.currentMode = modeManager.selectedMode
        services.modes = modeManager

        // Hotkey listener: key down starts and key up stops a dictation
        // through the controller.
        let hotkey = services.hotkeys.install(controller: controller)

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
        // as soon as setup finishes (including the onboarding Try it step).
        if let settings { syncHotkeys(from: settings) }

        diagLog("[Parrot:Setup] Starting HotkeyManager")
        services.hotkeys.start()

        // The service slots that have no setup above start here.
        services.startServices()

        // Post-setup: log the full state so we can diagnose issues from the log alone.
        diagLog("[Parrot:Setup] === SETUP COMPLETE ===")
        diagLog("[Parrot:Setup] Model ready: \(isModelReady)")
        diagLog("[Parrot:Setup] Mic permission: \(microphonePermissionGranted)")
        diagLog("[Parrot:Setup] Accessibility: \(accessOK)")
        diagLog("[Parrot:Setup] Hotkey binding: keyCode=\(hotkey.binding.keyCode), modifierOnly=\(hotkey.binding.isModifierOnly), mouseButton=\(hotkey.binding.isMouseButton)")
    }

    // MARK: - Recording Pipeline

    /// Begins capturing audio from the microphone. Allowed during model
    /// download; transcription fails with a clear error if the model is not
    /// ready when recording stops.
    func startRecording(trigger: RecordingTrigger = .menu) {
        controller.start(trigger: trigger)
    }

    /// Stops recording, transcribes captured audio, and inserts the result as text.
    func stopRecording(trigger: RecordingTrigger = .menu) {
        controller.stop(trigger: trigger)
    }

    // MARK: - Launch at Login

    /// Re-reads the login item status from ServiceManagement.
    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters Parrot as a login item, then reflects the
    /// real status. Failures surface as a toast and leave the toggle showing
    /// what the system reports.
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            diagLog("[Parrot:LoginItem] \(enabled ? "register" : "unregister") FAILED: \(error)")
            showTransientError("Could not change Launch at Login: \(error.localizedDescription)")
        }
        if enabled, service.status == .requiresApproval {
            showTransientError("Allow Parrot in System Settings > General > Login Items to launch at login.")
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshLaunchAtLogin()
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
    func startEnhanceRecording(trigger: RecordingTrigger = .menu) {
        isEnhanceMode = true
        startRecording(trigger: trigger)
    }

    /// Toggles dictation: starts recording if idle, stops (and transcribes) if
    /// currently recording. Used by the `parrot://` URL scheme and tap-to-toggle.
    func toggleDictation(trigger: RecordingTrigger = .menu) {
        controller.toggle(trigger: trigger)
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
        controller.cancel()
    }

    // MARK: - Hotkey Sync

    /// Applies the saved dictation binding to the hotkey listener (see
    /// `HotkeyCenter.apply`). Views read the bindings from `settings.hotkeys`.
    func syncHotkeys(from settings: AppSettings) {
        guard hotkeyManager != nil else { return }
        services.hotkeys.apply(settings)
    }

    /// Converts a UI-level HotkeyBinding to the CGEvent-level GlobalHotkeyBinding.
    static func toGlobalBinding(_ binding: HotkeyBinding) -> HotkeyManager.GlobalHotkeyBinding {
        HotkeyCenter.toGlobalBinding(binding)
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

// MARK: - Dictation Status

/// Mirrors the controller's progress into the status the views read, with
/// the same updates the recording pipeline made before it moved out.
extension AppState: DictationControllerDelegate {

    func dictationWillOpenMic(_ session: DictationSession) {
        if case .error = currentStatus {
            errorMessage = nil
        }
        // Pause level monitoring before recording to avoid engine conflicts.
        pauseLevelMeter()
    }

    func dictationDidStartRecording(_ session: DictationSession) {
        isRecording = true
        recordingState = .recording
        currentStatus = .recording
        errorMessage = nil
    }

    func dictationDidFailToStart(_ session: DictationSession, error: Error) {
        currentStatus = .error("Recording failed: \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        // Resume level monitoring since recording failed.
        resumeLevelMeterIfVisible()
    }

    func dictationDidStopRecording(_ session: DictationSession) {
        isRecording = false
        recordingState = .processing
        session.forceRefinement = isEnhanceMode
    }

    func dictationDidBeginProcessing(_ session: DictationSession) {
        currentStatus = .processing
    }

    func dictationDidEnd(_ session: DictationSession) {
        if session.isCancelled {
            isRecording = false
            recordingState = .idle
            currentStatus = .idle
            recordingDuration = 0
            waveformAmplitudes = []
            return
        }

        switch session.outcome {
        case .pasted, .copiedOnly:
            lastTranscription = session.text
            recordingState = .idle
            currentStatus = .idle
            recordingDuration = 0
            waveformAmplitudes = []
            isEnhanceMode = false
            settings?.general.successfulDictationCount += 1
        case .failed(let message):
            diagLog("[Parrot:AppState] Transcription FAILED: \(message)")
            recordingState = .idle
            currentStatus = .error("Transcription failed: \(message)")
            errorMessage = message
            isEnhanceMode = false
        default:
            // Discarded (too short or empty) or ended without delivery.
            recordingState = .idle
            currentStatus = .idle
        }

        // Resume the meter only if a view showing it is on screen.
        resumeLevelMeterIfVisible()
    }
}

// MARK: - Recorder Overlay

extension AppState: RecorderUIPresenting {
    func showRecorder() {
        RecordingOverlayPanel.show(appState: self)
    }

    func hideRecorder() {
        RecordingOverlayPanel.hide()
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
