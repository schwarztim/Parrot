import SwiftUI

/// The landing page (ui 3.2): start recording, the current mode, shortcuts
/// and microphone rows, first-run tips and the stats panel. [UI]
struct HomeView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    @State private var showsMicPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // One-time AI Refinement discovery nudge.
                if appSettings.shouldShowRefinementNudge {
                    refinementNudge
                }

                FirstRunToastStack(screen: .home, satisfied: satisfiedToasts)

                rows

                StatsPanelView()
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: statusIconName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back")
                    .font(.title2.weight(.semibold))
                Text(statusLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIconName: String {
        switch appState.recordingState {
        case .idle: return "waveform"
        case .recording: return "mic.fill"
        case .processing: return "brain"
        }
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle: return .green
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var statusLabel: String {
        switch appState.recordingState {
        case .idle: return "Ready to record."
        case .recording: return "Recording..."
        case .processing: return "Processing audio..."
        }
    }

    // MARK: - Rows

    private var rows: some View {
        let hotkeys = appSettings.hotkeys
        let pushToTalk = hotkeys.shortcut(for: .pushToTalk)
        let toggle = hotkeys.shortcut(for: .toggleRecording)
        let startKey = toggle.isEmpty ? pushToTalk : toggle
        let devices = appState.services.devices

        return VStack(spacing: 0) {
            HomeRow(
                systemImage: "mic.circle.fill",
                title: "Start recording",
                caption: "Turn your voice to text with a single click.",
                action: { appState.toggleDictation(trigger: .menu) }
            ) {
                if !startKey.isEmpty {
                    ShortcutKeycaps(shortcut: startKey)
                }
            }
            Divider().padding(.leading, 44)
            HomeRow(
                systemImage: "square.stack.3d.up",
                title: "\(appState.currentMode?.name ?? "Default") mode",
                caption: "Create a mode or change how Parrot writes.",
                action: { appState.navigation.request(.modes) }
            )
            Divider().padding(.leading, 44)
            HomeRow(
                systemImage: "keyboard",
                title: "Customize your shortcuts",
                caption: pushToTalk.isEmpty ? "No push-to-talk key yet." : "Hold \(pushToTalk.displayName) to talk.",
                action: { appState.navigation.request(.shortcuts) }
            ) {
                if !pushToTalk.isEmpty {
                    ShortcutKeycaps(shortcut: pushToTalk)
                }
            }
            Divider().padding(.leading, 44)
            HomeRow(
                systemImage: micIconName,
                title: devices.activeDevice?.name ?? "Microphone",
                caption: micCaption,
                action: { showsMicPicker = true }
            ) {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .popover(isPresented: $showsMicPicker, arrowEdge: .bottom) {
                DevicePickerView(devices: devices) { showsMicPicker = false }
                    .padding(12)
                    .frame(width: 300)
            }
            Divider().padding(.leading, 44)
            HomeRow(
                systemImage: "text.book.closed",
                title: "Add vocabulary",
                caption: "Teach Parrot names and terms it should spell right.",
                action: { appState.navigation.request(.vocabulary) }
            )
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
    }

    private var micIconName: String {
        switch appState.microphoneStatus {
        case .connected: return "mic.fill"
        case .disconnected: return "mic.slash"
        case .permissionDenied: return "mic.slash.fill"
        case .permissionNotDetermined: return "mic.badge.xmark"
        }
    }

    private var micCaption: String {
        switch appState.microphoneStatus {
        case .connected:
            return appState.services.devices.followsSystemDefault ? "Following the system default." : "Pinned microphone."
        case .disconnected:
            return "No microphone connected."
        case .permissionDenied:
            return "Microphone access is off. Allow it in System Settings."
        case .permissionNotDetermined:
            return "Parrot will ask for microphone access on first use."
        }
    }

    /// Tips whose suggestion the user already followed.
    private var satisfiedToasts: Set<String> {
        var satisfied: Set<String> = []
        if appSettings.general.successfulDictationCount > 0 { satisfied.insert("home.firstDictation") }
        if appSettings.general.typingWPM != GeneralSettings.defaultTypingWPM { satisfied.insert("home.typingTest") }
        if appSettings.recorder.recordingWindowStyle == .mini { satisfied.insert("home.miniRecorder") }
        return satisfied
    }

    // MARK: - Refinement Nudge

    private var refinementNudge: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Polish your dictation")
                    .font(.headline)
                Spacer()
                Button {
                    appSettings.general.refinementNudgeDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("Parrot can clean up punctuation and phrasing with a local or cloud AI before pasting. Off by default.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Set up") {
                    appSettings.general.refinementNudgeDismissed = true
                    appState.navigation.modelsSegment = .language
                    appState.navigation.request(.models)
                }
                .buttonStyle(.borderedProminent)

                Button("No thanks") {
                    appSettings.general.refinementNudgeDismissed = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.purple.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Row

/// One Home action row: icon, title, caption and an optional trailing view.
private struct HomeRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let caption: String
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private extension HomeRow where Trailing == EmptyView {
    init(systemImage: String, title: String, caption: String, action: @escaping () -> Void) {
        self.init(systemImage: systemImage, title: title, caption: caption, action: action, trailing: { EmptyView() })
    }
}

#Preview {
    HomeView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 600, height: 700)
}
