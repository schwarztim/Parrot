import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // App Icon / Status Icon
                statusIcon

                // Current Mode
                currentModeSection

                // App State
                appStateIndicator

                // Microphone Status
                microphoneStatusSection

                // Quick Start
                quickStartSection
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Status Icon

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 80, height: 80)

            Image(systemName: statusIconName)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(statusColor)
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
        case .idle: return .secondary
        case .recording: return .red
        case .processing: return .orange
        }
    }

    // MARK: - Current Mode

    private var currentModeSection: some View {
        VStack(spacing: 6) {
            Text("Current Mode")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)

                Text(appState.currentMode?.name ?? "None")
                    .font(.title2.weight(.semibold))
            }
        }
    }

    // MARK: - App State Indicator

    private var appStateIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appStateColor)
                .frame(width: 8, height: 8)

            Text(appStateLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
        )
    }

    private var appStateLabel: String {
        switch appState.recordingState {
        case .idle: return "Idle -- Ready to record"
        case .recording: return "Recording..."
        case .processing: return "Processing audio..."
        }
    }

    private var appStateColor: Color {
        switch appState.recordingState {
        case .idle: return .green
        case .recording: return .red
        case .processing: return .orange
        }
    }

    // MARK: - Microphone Status

    private var microphoneStatusSection: some View {
        HStack(spacing: 8) {
            Image(systemName: micIconName)
                .foregroundStyle(micStatusColor)
                .font(.callout)

            Text(appState.microphoneStatus.rawValue)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var micIconName: String {
        switch appState.microphoneStatus {
        case .connected: return "mic.fill"
        case .disconnected: return "mic.slash"
        case .permissionDenied: return "mic.slash.fill"
        case .permissionNotDetermined: return "mic.badge.xmark"
        }
    }

    private var micStatusColor: Color {
        switch appState.microphoneStatus {
        case .connected: return .green
        case .disconnected: return .orange
        case .permissionDenied: return .red
        case .permissionNotDetermined: return .secondary
        }
    }

    // MARK: - Quick Start

    private var quickStartSection: some View {
        VStack(spacing: 12) {
            Divider()
                .padding(.horizontal, 20)

            VStack(spacing: 8) {
                Text("Quick Start")
                    .font(.headline)

                VStack(spacing: 4) {
                    instructionRow(
                        key: "Right Option",
                        action: "Hold to record (push to talk)"
                    )
                    instructionRow(
                        key: "Right Option",
                        action: "Tap to toggle recording"
                    )
                    instructionRow(
                        key: "Esc",
                        action: "Cancel recording"
                    )
                }
            }
        }
    }

    private func instructionRow(key: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                )

            Text(action)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: 320)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
        .frame(width: 500, height: 500)
}
