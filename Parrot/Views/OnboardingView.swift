import AppKit
import SwiftUI

// MARK: - Flow

/// The onboarding pages, in order (ui 4). The raw value is what
/// `GeneralSettings.onboardingProgress` saves, so a relaunch resumes on the
/// same page. Parrot has no paywall page.
enum OnboardingPage: Int, CaseIterable {
    case welcome
    case permissions
    case microphone
    case model
    case tryIt

    var label: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .microphone: return "Microphone"
        case .model: return "Model"
        case .tryIt: return "Try it"
        }
    }

    /// The page saved `progress` points at, clamped into range.
    static func resumed(from progress: Int) -> OnboardingPage {
        let last = allCases.count - 1
        return OnboardingPage(rawValue: min(max(progress, 0), last)) ?? .welcome
    }

    /// The next page, or self on the last page.
    var next: OnboardingPage { OnboardingPage(rawValue: rawValue + 1) ?? self }

    /// The previous page, or self on the first page.
    var previous: OnboardingPage { OnboardingPage(rawValue: rawValue - 1) ?? self }

    var isLast: Bool { self == Self.allCases.last }

    /// Share of the flow done when this page shows (0 on Welcome, 1 on the
    /// last page).
    var fraction: Double { Double(rawValue) / Double(Self.allCases.count - 1) }
}

/// Pure onboarding rules: missing permissions, push-to-talk presets and
/// completion. [UI]
enum OnboardingFlow {

    /// A one-tap push-to-talk choice on the Try it page.
    struct Preset: Identifiable, Equatable {
        let name: String
        let shortcut: Shortcut
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Right Command", shortcut: .key(0x36)),
        Preset(name: "Right Option", shortcut: .key(0x3D)),
        Preset(name: "Fn", shortcut: .key(Shortcut.functionKeyCode)),
    ]

    /// The preset matching `shortcut`, or nil for a custom key.
    static func preset(matching shortcut: Shortcut) -> Preset? {
        presets.first { $0.shortcut == shortcut }
    }

    /// Names of the permissions still missing, in page order.
    static func missingPermissions(microphone: Bool, accessibility: Bool, inputMonitoring: Bool) -> [String] {
        var missing: [String] = []
        if !microphone { missing.append("Microphone") }
        if !accessibility { missing.append("Accessibility") }
        if !inputMonitoring { missing.append("Input Monitoring") }
        return missing
    }

    /// Marks onboarding done and clears the saved page, so running it again
    /// later starts at Welcome.
    static func complete(_ general: GeneralSettings) {
        general.hasCompletedOnboarding = true
        general.onboardingProgress = 0
    }
}

// MARK: - View

/// The onboarding window: Welcome, Permissions, Microphone test, Local or
/// Cloud, and Try it, with a progress bar and resumable progress. [UI]
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page: OnboardingPage = .welcome
    @State private var permissionTimer: Timer?
    @State private var pendingWarning: WarningState?
    @State private var levelHistory: [Float] = []
    @State private var scratchpadText = ""
    @State private var customShortcut: Shortcut?

    /// Called when the user completes onboarding. The host (WindowManager)
    /// closes the onboarding window and shows the main window.
    var onComplete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            VStack {
                Spacer(minLength: 0)
                content
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(page)
                Spacer(minLength: 0)
                navigationButtons
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .frame(width: 560, height: 540)
        .background(Color(.windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)
        .warningModal($pendingWarning) { _ in
            page = page.next
        }
        .onAppear {
            if appState.permissionsManager == nil {
                appState.initPermissionsManager()
            }
            // Start the model download now so it is ready (or nearly so) by
            // the time the user reaches the Model page.
            appState.beginModelPreparation()
            page = OnboardingPage.resumed(from: appSettings.general.onboardingProgress)
            enter(page)
        }
        .onChange(of: page) { old, new in
            appSettings.general.onboardingProgress = new.rawValue
            leave(old)
            enter(new)
        }
        .onChange(of: appState.inputLevel) { _, level in
            levelHistory.append(level)
            if levelHistory.count > 32 { levelHistory.removeFirst(levelHistory.count - 32) }
        }
        .onDisappear {
            leave(page)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: welcomePage
        case .permissions: permissionsPage
        case .microphone: microphonePage
        case .model: modelPage
        case .tryIt: tryItPage
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: 6) {
            ProgressView(value: page.fraction)
                .progressViewStyle(.linear)
            HStack {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { item in
                    Text(item.label)
                        .font(.system(size: 10, weight: item == page ? .semibold : .regular))
                        .foregroundStyle(item == page ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 22) {
            appIconView

            VStack(spacing: 8) {
                Text("Welcome to Parrot")
                    .font(.largeTitle.weight(.bold))
                Text("Let's get you set up to dictate anywhere on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Estimated time: under 2 minutes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "mic.fill", text: "Hold a key, speak, and let go")
                featureRow(icon: "cpu", text: "Transcribe on your Mac or in the cloud")
                featureRow(icon: "lock.shield", text: "Local mode keeps your audio on this Mac")
            }
        }
    }

    /// The installed app icon, falling back to a gradient waveform glyph when
    /// running before the bundle icon is available (e.g. SwiftUI previews).
    @ViewBuilder
    private var appIconView: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 88, height: 88)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 88, height: 88)
                Image(systemName: "waveform")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permissions

    private var permissionsPage: some View {
        VStack(spacing: 18) {
            pageTitle("Let's set up permissions", "Parrot asks only for what dictation needs. Each row turns green as soon as macOS grants it.")

            VStack(spacing: 10) {
                PermissionRow(
                    systemImage: "mic.fill",
                    title: "Allow Microphone Access",
                    detail: "To hear you, only while you dictate.",
                    granted: appState.microphonePermissionGranted,
                    allow: { appState.startOnboardingMicMonitoring() }
                )
                PermissionRow(
                    systemImage: "hand.raised.fill",
                    title: "Allow Accessibility Access",
                    detail: "To paste your text where the cursor is.",
                    granted: appState.accessibilityPermissionGranted,
                    allow: requestAccessibility
                )
                PermissionRow(
                    systemImage: "keyboard",
                    title: "Allow Input Monitoring",
                    detail: "To notice your push-to-talk key in any app.",
                    granted: appState.inputMonitoringPermissionGranted,
                    allow: requestInputMonitoring
                )
            }

            Text("macOS may ask you to quit and reopen Parrot after a change in System Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var missingPermissions: [String] {
        OnboardingFlow.missingPermissions(
            microphone: appState.microphonePermissionGranted,
            accessibility: appState.accessibilityPermissionGranted,
            inputMonitoring: appState.inputMonitoringPermissionGranted
        )
    }

    private func requestAccessibility() {
        guard let permissions = appState.permissionsManager else { return }
        // AX trust has no callback; the page's timer notices the grant.
        permissions.requestAccessibilityAccess()
        permissions.openSystemPreferences(for: .accessibility)
    }

    private func requestInputMonitoring() {
        guard let permissions = appState.permissionsManager else { return }
        if !permissions.requestInputMonitoringAccess() {
            permissions.openSystemPreferences(for: .inputMonitoring)
        }
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        appState.refreshPermissionHealth()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                appState.refreshPermissionHealth()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Microphone Test

    private var microphonePage: some View {
        VStack(spacing: 16) {
            pageTitle("Let's test your microphone", "Say \"This is my first recording with Parrot\" and watch the bars.")

            if appState.microphonePermissionGranted {
                LevelBarsView(levels: levelHistory.isEmpty ? [] : levelHistory.map { min(1, $0 * 4) }, barCount: 32, barWidth: 4, spacing: 3, height: 50, color: .accentColor)
                    .frame(height: 56)
                Text("Speak and see if the waves react.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow Microphone Access") {
                    appState.startOnboardingMicMonitoring()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("No response? Try changing your input device below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    DevicePickerView(devices: appState.services.devices) {
                        // Restart the meter on the new device.
                        appState.stopInputMonitoring()
                        levelHistory = []
                        appState.startInputMonitoring()
                    }
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
            }
            .frame(maxWidth: 380)
        }
    }

    // MARK: - Model

    private var modelPage: some View {
        let provider = appSettings.transcription.transcriptionProvider
        let isLocal = provider == .parakeet
        return VStack(spacing: 18) {
            pageTitle("Select your preferred model", "You can change this any time under Models.")

            HStack(spacing: 14) {
                ModelChoiceCard(
                    systemImage: "lock.laptopcomputer",
                    title: "Local",
                    detail: "Works offline with complete privacy. Best on Apple silicon.",
                    isSelected: isLocal
                ) {
                    appSettings.transcription.transcriptionProvider = .parakeet
                }
                ModelChoiceCard(
                    systemImage: "cloud",
                    title: "Cloud",
                    detail: "Uses OpenAI and needs internet. Audio is sent for transcription only.",
                    isSelected: !isLocal
                ) {
                    appSettings.transcription.transcriptionProvider = .openAI
                }
            }

            Group {
                if isLocal {
                    if appState.isModelReady {
                        Label("Download complete", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if appState.isDownloadingModel {
                        VStack(spacing: 6) {
                            ProgressView(value: appState.modelDownloadProgress)
                                .frame(width: 260)
                            Text("Downloading Parakeet V3... \(Int(appState.modelDownloadProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Text("The local model (about 800 MB) has not downloaded yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Download") { appState.setup() }
                        }
                    }
                } else if appSettings.credentials.key(for: .openAI).isEmpty {
                    Text("Add your OpenAI API key under Models after setup. Until then Parrot can't transcribe in the cloud.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                } else {
                    Label("Your OpenAI key is set", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.callout)
        }
    }

    // MARK: - Try It

    private var pushToTalk: Shortcut {
        appSettings.hotkeys.shortcut(for: .pushToTalk)
    }

    private var tryItPage: some View {
        VStack(spacing: 14) {
            pageTitle("Try the shortcut", "Choose the key you hold to talk.")

            HStack(spacing: 8) {
                ForEach(OnboardingFlow.presets) { preset in
                    Button {
                        setPushToTalk(preset.shortcut)
                    } label: {
                        Text(preset.name)
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.bordered)
                    .tint(pushToTalk == preset.shortcut ? .accentColor : nil)
                    .controlSize(.large)
                }
            }

            HotkeyRecorderView(
                label: "Custom",
                summary: OnboardingFlow.preset(matching: pushToTalk) == nil && !pushToTalk.isEmpty ? "Your own key" : nil,
                shortcut: Binding(
                    get: { pushToTalk.isEmpty ? nil : pushToTalk },
                    set: { setPushToTalk($0 ?? .none) }
                ),
                allowsMouse: false
            )
            .frame(maxWidth: 380)

            if pushToTalk.isEmpty {
                Text("Pick a key above to continue.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Text("Press and hold")
                    ShortcutKeycaps(shortcut: pushToTalk)
                    Text("and start speaking.")
                }
                .font(.callout)
            }

            Text("Click the box, then say: \"Parrot, please write this down for me.\"")
                .font(.caption)
                .foregroundStyle(.secondary)

            recordingStatus

            TextEditor(text: $scratchpadText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separatorColor), lineWidth: 1))

            if scratchpadText.isEmpty, appState.lastTranscription != nil, !appState.accessibilityPermissionGranted {
                Text("Transcribed, but could not paste. Your text is on the clipboard (press Cmd+V). Grant Accessibility to paste automatically.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var recordingStatus: some View {
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
                Text(scratchpadText.isEmpty ? "Ready when you are" : "Nice. That works in every app.")
                    .foregroundStyle(scratchpadText.isEmpty ? Color.secondary : Color.green)
            }
        }
        .font(.callout.weight(.medium))
        .frame(height: 20)
    }

    private func setPushToTalk(_ shortcut: Shortcut) {
        appSettings.hotkeys.setShortcut(shortcut, for: .pushToTalk)
        // HotkeyCenter follows the settings; this covers a listener that
        // started before the change.
        appState.syncHotkeys(from: appSettings)
    }

    // MARK: - Shared

    private func pageTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if page != .welcome {
                Button("Back") { page = page.previous }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if page.isLast {
                Button {
                    finish()
                } label: {
                    Text("Complete onboarding")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    advance()
                } label: {
                    Text(page == .welcome ? "Get Started" : continueTitle)
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var continueTitle: String {
        if page == .model, appSettings.transcription.transcriptionProvider == .parakeet, !appState.isModelReady {
            return "Continue while it downloads"
        }
        return "Continue"
    }

    private func advance() {
        if page == .permissions, !missingPermissions.isEmpty {
            pendingWarning = .permissionsRequired(missing: missingPermissions)
            return
        }
        page = page.next
    }

    private func finish() {
        leave(page)
        OnboardingFlow.complete(appSettings.general)
        onComplete?()
    }

    /// Starts each page's live parts.
    private func enter(_ page: OnboardingPage) {
        switch page {
        case .permissions:
            startPermissionPolling()
        case .microphone:
            levelHistory = []
            if appState.microphonePermissionGranted {
                appState.startInputMonitoring()
            } else {
                appState.startOnboardingMicMonitoring()
            }
        case .tryIt:
            // Try it dictates for real, so it needs the hotkey listener and
            // the rest of the pipeline that setup creates. Idempotent.
            appState.setup()
        case .welcome, .model:
            break
        }
    }

    /// Stops what `enter` started.
    private func leave(_ page: OnboardingPage) {
        switch page {
        case .permissions:
            stopPermissionPolling()
        case .microphone:
            appState.stopInputMonitoring()
        case .welcome, .model, .tryIt:
            break
        }
    }
}

// MARK: - Pieces

/// One permission: what it is for, and Allow or a green tick.
private struct PermissionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Granted")
            } else {
                Button("Allow", action: allow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(granted ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

/// The Local or Cloud card.
private struct ModelChoiceCard: View {
    let systemImage: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 200, height: 130, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color(.separatorColor), lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .environment(AppState())
        .environment(AppSettings())
}
