import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var currentStep: OnboardingStep = .welcome
    @State private var inputMonitoringTimer: Timer?
    @State private var accessibilityTimer: Timer?

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
            // Ensure PermissionsManager is available for permission steps
            if appState.permissionsManager == nil {
                appState.initPermissionsManager()
            }
        }
        .onDisappear {
            inputMonitoringTimer?.invalidate()
            inputMonitoringTimer = nil
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
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
        }
    }

    private func stepLabel(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Welcome"
        case .microphonePermission: return "Microphone"
        case .inputMonitoring: return "Hotkey"
        case .accessibility: return "Paste"
        case .modelDownload: return "Model"
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            // App Icon
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
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
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

    // MARK: - Step 3: Input Monitoring

    private var inputMonitoringStep: some View {
        VStack(spacing: 24) {
            permissionIcon(
                systemName: "keyboard",
                color: .blue,
                granted: appState.inputMonitoringPermissionGranted
            )

            VStack(spacing: 8) {
                Text("Input Monitoring")
                    .font(.title.weight(.bold))

                Text(
                    "Parrot needs Input Monitoring permission to detect keyboard shortcuts for recording."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            }

            if appState.inputMonitoringPermissionGranted {
                Label("Input monitoring enabled", systemImage: "checkmark.circle.fill")
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

                    Text(
                        "Enable Parrot in Privacy & Security > Input Monitoring"
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            if currentStep == .modelDownload {
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
        appState.hasCompletedOnboarding = true
        appSettings.hasCompletedOnboarding = true
        inputMonitoringTimer?.invalidate()
        inputMonitoringTimer = nil
        onComplete?()
    }

    // MARK: - Permission Actions

    private func requestMicrophonePermission() {
        Task {
            guard let permissions = appState.permissionsManager else { return }
            let granted = await permissions.requestMicrophoneAccess()
            await MainActor.run {
                appState.microphonePermissionGranted = granted
            }
        }
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
