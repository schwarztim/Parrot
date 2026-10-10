import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var currentStep: OnboardingStep = .welcome
    @State private var inputMonitoringTimer: Timer?
    @State private var accessibilityTimer: Timer?
    @State private var scratchpadText: String = ""
    @State private var hotkeyProbe: HotkeyProbe?
    @State private var hotkeyDetected = false

    /// Called when the user completes onboarding. The host (AppDelegate)
    /// uses this to close the onboarding window and show the main window.
    var onComplete: (() -> Void)?

    private let totalSteps = OnboardingStep.allCases.count

    var body: some View {
        VStack(spacing: 0) {

            // Progress Bar
            progressBar

            // Content
            VStack {
                Spacer()

                Group {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .microphonePermission:
                        microphoneStep
                    case .inputMonitoring:
                        inputMonitoringStep
                    case .accessibility:
                        accessibilityStep
                    case .modelDownload:
                        modelDownloadStep
                    case .tryIt:
                        tryItStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                Spacer()

                // Navigation
                navigationButtons
            }
            .padding(40)
        }
        .frame(width: 520, height: 480)
        .background(Color(.windowBackgroundColor))
        .animation(.easeInOut(duration: 0.3), value: currentStep)
        .onAppear {
            // Ensure PermissionsManager is available for permission steps.
            if appState.permissionsManager == nil {
                appState.initPermissionsManager()
            }
            // Start the ~800 MB model download now so it is ready (or nearly
            // so) by the time the user reaches the Model step.
            appState.beginModelPreparation()
            configureStep(currentStep)
        }
        .onChange(of: currentStep) { _, newStep in
            configureStep(newStep)
        }
        .onDisappear {
            inputMonitoringTimer?.invalidate()
            inputMonitoringTimer = nil
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            appState.stopInputMonitoring()
            hotkeyProbe?.stop()
            hotkeyProbe = nil
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                stepIndicator(for: step)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
    }

    private func stepIndicator(for step: OnboardingStep) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(stepColor(for: step))
                    .frame(width: 28, height: 28)

                if isStepComplete(step) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            step == currentStep ? .white : .secondary
                        )
                }
            }

            Text(stepLabel(for: step))
                .font(.system(size: 10))
                .foregroundStyle(
                    step == currentStep ? .primary : .secondary
                )
        }
        .frame(maxWidth: .infinity)
    }

    private func stepColor(for step: OnboardingStep) -> Color {
        if isStepComplete(step) {
            return .green
        } else if step == currentStep {
            return .accentColor
        } else {
            return Color(.controlBackgroundColor)
        }
    }

    private func isStepComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome:
            return currentStep.rawValue > OnboardingStep.welcome.rawValue
        case .microphonePermission:
            return appState.microphonePermissionGranted
        case .inputMonitoring:
            return appState.inputMonitoringPermissionGranted
        case .accessibility:
            return appState.accessibilityPermissionGranted
        case .modelDownload:
            return appState.isModelReady
        case .tryIt:
            return !scratchpadText.isEmpty
        }
    }

    private func stepLabel(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Welcome"
        case .microphonePermission: return "Microphone"
        case .inputMonitoring: return "Hotkey"
        case .accessibility: return "Paste"
        case .modelDownload: return "Model"
        case .tryIt: return "Try it"
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            // App Icon (real bundle icon when available, gradient glyph otherwise)
            appIconView

            VStack(spacing: 8) {
                Text("Welcome to Parrot")
                    .font(.largeTitle.weight(.bold))

                Text("Fast, private voice-to-text powered by on-device AI.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "mic.fill", text: "Record with a keyboard shortcut")
                featureRow(icon: "cpu", text: "Transcribe locally with neural models")
                featureRow(icon: "lock.shield", text: "Your audio never leaves your Mac")
            }
            .padding(.top, 8)
        }
    }

    /// The installed app icon, falling back to a gradient waveform glyph when
    /// running before the bundle icon is available (e.g. SwiftUI previews).
    @ViewBuilder
    private var appIconView: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [Color.green, Color.teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)

                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 2: Microphone Permission

    private var microphoneStep: some View {
        VStack(spacing: 24) {
            permissionIcon(
                systemName: "mic.fill",
                color: .red,
                granted: appState.microphonePermissionGranted
            )

            VStack(spacing: 8) {
                Text("Microphone Access")
                    .font(.title.weight(.bold))

                Text(
                    "Parrot needs microphone access to record your voice for transcription."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            }

            if appState.microphonePermissionGranted {
                VStack(spacing: 10) {
                    Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)

                    micLevelMeter
                    Text("Say something and watch it react.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Button {
                    requestMicrophonePermission()
                } label: {
                    Text("Grant Access")
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    /// A simple horizontal bar reflecting the live input level (0...1).
    private var micLevelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.separatorColor).opacity(0.4))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, appState.inputLevel))))
                    .animation(.easeOut(duration: 0.08), value: appState.inputLevel)
            }
        }
        .frame(width: 220, height: 8)
    }

    // MARK: - Step 3: Input Monitoring

    private var inputMonitoringStep: some View {
        VStack(spacing: 24) {
            permissionIcon(
                systemName: "keyboard",
                color: .blue,
                granted: appState.inputMonitoringPermissionGranted
            )

            VStack(spacing: 8) {
                Text("Your dictation key")
                    .font(.title.weight(.bold))

                Text(
                    "Parrot watches for one key: \(appSettings.hotkeys.hotkeyBinding.displayName). Grant Input Monitoring, then hold the key to test it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }

            if hotkeyDetected || appState.inputMonitoringPermissionGranted {
                Label(
                    hotkeyDetected ? "Key detected. You are set." : "Input monitoring enabled",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            } else {
                VStack(spacing: 12) {
                    Button {
                        openInputMonitoringSettings()
                    } label: {
                        Text("Open System Settings")
                            .frame(width: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("Enable Parrot in Privacy & Security > Input Monitoring, then hold \(appSettings.hotkeys.hotkeyBinding.displayName) to confirm.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    // MARK: - Step 4: Accessibility (Auto-paste)

    private var accessibilityStep: some View {
        VStack(spacing: 24) {
            permissionIcon(
                systemName: "doc.on.clipboard",
                color: .orange,
                granted: appState.accessibilityPermissionGranted
            )

            VStack(spacing: 8) {
                Text("Auto-paste")
                    .font(.title.weight(.bold))

                Text(
                    "After transcribing, Parrot presses Cmd+V for you so text lands at your cursor. macOS calls this Accessibility access."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }

            if appState.accessibilityPermissionGranted {
                Label("Auto-paste enabled", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 12) {
                    Button {
                        requestAccessibility()
                    } label: {
                        Text("Grant Access")
                            .frame(width: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text(
                        "Enable Parrot in Privacy & Security > Accessibility. Used for one thing: pasting your dictation. Skip it and Parrot copies to your clipboard instead."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                }
            }
        }
    }

    // MARK: - Step 5: Model Download

    private var modelDownloadStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 80, height: 80)

                if appState.isModelReady {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 36))
                        .foregroundStyle(.purple)
                }
            }

            VStack(spacing: 8) {
                Text("Download Model")
                    .font(.title.weight(.bold))

                Text(
                    "Download the Parakeet V3 speech recognition model (~800 MB). This model runs entirely on your Mac."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }

            if appState.isModelReady {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else if appState.isDownloadingModel {
                VStack(spacing: 8) {
                    ProgressView(value: appState.modelDownloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 240)

                    Text(
                        "Downloading... \(Int(appState.modelDownloadProgress * 100))%"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    startModelDownload()
                } label: {
                    Label("Download Parakeet V3", systemImage: "arrow.down.circle")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // Model specs
            HStack(spacing: 20) {
                modelSpec(label: "Size", value: "~800 MB")
                modelSpec(label: "Languages", value: "25")
                modelSpec(label: "Speed", value: "~190x RT")
            }
            .padding(.top, 4)
        }
    }

    private func modelSpec(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.weight(.medium))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Step 6: Try It

    private var tryItStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Try it out")
                    .font(.title.weight(.bold))

                Text(tryItInstruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            // Live recording indicator.
            HStack(spacing: 8) {
                switch appState.recordingState {
                case .recording:
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Listening...").foregroundStyle(.red)
                case .processing:
                    ProgressView().controlSize(.small)
                    Text("Transcribing...").foregroundStyle(.secondary)
                case .idle:
                    Image(systemName: scratchpadText.isEmpty ? "keyboard" : "checkmark.circle.fill")
                        .foregroundStyle(scratchpadText.isEmpty ? Color.secondary : Color.green)
                    Text(scratchpadText.isEmpty ? "Ready when you are" : "That works in every app")
                        .foregroundStyle(scratchpadText.isEmpty ? Color.secondary : Color.green)
                }
            }
            .font(.callout.weight(.medium))
            .frame(height: 20)

            // Scratchpad the dictation pastes into.
            TextEditor(text: $scratchpadText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(.separatorColor), lineWidth: 1)
                )

            // Diagnose the paste-failure case inline.
            if !scratchpadText.isEmpty {
                Label("Nice. You are all set.", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if appState.lastTranscription != nil && !appState.accessibilityPermissionGranted {
                VStack(spacing: 6) {
                    Text("Transcribed, but could not paste. Your text is on the clipboard (press Cmd+V). Grant Accessibility to enable auto-paste.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Fix Accessibility") {
                        currentStep = .accessibility
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var tryItInstruction: String {
        let key = appSettings.hotkeys.hotkeyBinding.displayName
        return "Click the box below, then hold \(key) and say: testing Parrot one two three. Let go and watch it appear."
    }

    // MARK: - Permission Icon Helper

    private func permissionIcon(systemName: String, color: Color, granted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 80, height: 80)

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 36))
                    .foregroundStyle(color)
            }
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            // Back
            if currentStep != .welcome {
                Button("Back") {
                    goToPreviousStep()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Next / Get Started
            if currentStep == OnboardingStep.allCases.last {
                Button {
                    completeOnboarding()
                } label: {
                    Text("Get Started")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canProceedFromCurrentStep)
            } else {
                Button {
                    goToNextStep()
                } label: {
                    Text("Continue")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var canProceedFromCurrentStep: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .microphonePermission:
            return appState.microphonePermissionGranted
        case .inputMonitoring:
            return appState.inputMonitoringPermissionGranted
        case .accessibility:
            // Skippable: clipboard-only is a valid degraded mode.
            return true
        case .modelDownload:
            return appState.isModelReady
        case .tryIt:
            // Never trap the user: Finish is always available here. A
            // successful dictation is celebrated but not required (paste may
            // be intentionally skipped in the Accessibility step).
            return true
        }
    }

    // MARK: - Navigation Actions

    private func goToNextStep() {
        guard let nextRaw = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextRaw
    }

    private func goToPreviousStep() {
        guard let prevRaw = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevRaw
    }

    private func completeOnboarding() {
        appSettings.general.hasCompletedOnboarding = true
        inputMonitoringTimer?.invalidate()
        inputMonitoringTimer = nil
        onComplete?()
    }

    // MARK: - Permission Actions

    private func requestMicrophonePermission() {
        // Trigger the prompt by starting the audio engine (reliable on
        // self-signed builds), not AVCaptureDevice.requestAccess which can hang.
        appState.startOnboardingMicMonitoring()
    }

    private func openInputMonitoringSettings() {
        guard let permissions = appState.permissionsManager else {
            // Fallback: open System Settings directly
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            ) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        permissions.requestInputMonitoringAccess()
        startInputMonitoringPolling()
    }

    private func startInputMonitoringPolling() {
        inputMonitoringTimer?.invalidate()
        inputMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard let permissions = appState.permissionsManager else { return }
                let granted = permissions.checkInputMonitoringPermission()
                if granted {
                    appState.inputMonitoringPermissionGranted = true
                    inputMonitoringTimer?.invalidate()
                    inputMonitoringTimer = nil
                }
            }
        }
    }

    /// Starts and stops per-step live affordances (mic meter, hotkey probe) as
    /// the user moves through the wizard.
    private func configureStep(_ step: OnboardingStep) {
        // Mic level meter: only while on the microphone step.
        if step == .microphonePermission {
            if !appState.microphonePermissionGranted {
                appState.startOnboardingMicMonitoring()
            } else {
                appState.startInputMonitoring()
            }
        } else {
            appState.stopInputMonitoring()
        }

        // Functional hotkey probe: only while on the hotkey step.
        if step == .inputMonitoring {
            startHotkeyProbe()
        } else {
            hotkeyProbe?.stop()
            hotkeyProbe = nil
        }

        // Try it dictates for real, so it needs the hotkey listener and the
        // rest of the pipeline that setup creates. The model download starts
        // at Welcome, so the Model step's Download button (the only other
        // caller during onboarding) usually never appears. Idempotent.
        if step == .tryIt {
            appState.setup()
        }
    }

    private func startHotkeyProbe() {
        hotkeyDetected = false
        hotkeyProbe?.stop()
        let probe = HotkeyProbe(targetKeyCode: Int(appSettings.hotkeys.hotkeyBinding.keyCode))
        probe.onDetected = {
            hotkeyDetected = true
            // A live press is the strongest proof the key is detectable.
            appState.inputMonitoringPermissionGranted = true
        }
        probe.start()
        hotkeyProbe = probe
    }

    private func requestAccessibility() {
        guard let permissions = appState.permissionsManager else {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // Show the AX trust prompt and deep-link straight to the pane; AX trust
        // has no completion callback, so poll until it flips.
        permissions.requestAccessibilityAccess()
        permissions.openSystemPreferences(for: .accessibility)
        startAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard let permissions = appState.permissionsManager else { return }
                if permissions.checkAccessibilityPermission() {
                    appState.accessibilityPermissionGranted = true
                    accessibilityTimer?.invalidate()
                    accessibilityTimer = nil
                }
            }
        }
    }

    private func startModelDownload() {
        appState.setup()
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .environment(AppState())
        .environment(AppSettings())
}
