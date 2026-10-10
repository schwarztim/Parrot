import SwiftUI

/// Recording window style and launch at login. [UI]
struct GeneralSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var recorder = appSettings.recorder

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("General")
                        .font(.title2.weight(.semibold))
                    Text("Recording window and startup")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    // Recording Window Style
                    Section("Recording Window") {
                        Picker("Window Style", selection: $recorder.recordingWindowStyle) {
                            Text("Classic").tag(RecordingWindowStyle.classic)
                            Text("Mini").tag(RecordingWindowStyle.mini)
                            Text("None").tag(RecordingWindowStyle.none)
                        }
                        .pickerStyle(.radioGroup)

                        Text(windowStyleDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // General
                    Section("General") {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { appState.launchAtLogin },
                            set: { appState.setLaunchAtLogin($0) }
                        ))

                        Text(
                            "Automatically start Parrot when you log in to your Mac."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        // Show the real login item status, which can change in System Settings.
        .onAppear {
            appState.refreshLaunchAtLogin()
        }
    }

    private var windowStyleDescription: String {
        switch appSettings.recorder.recordingWindowStyle {
        case .classic:
            return "Larger window with full waveform visualization"
        case .mini:
            return "Compact horizontal bar"
        case .none:
            return "No recording window shown"
        }
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
