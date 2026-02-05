import SwiftUI

struct ConfigurationView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var apiKeyInput: String = ""
    @State private var showApiKey = false

    var body: some View {
        @Bindable var state = appState
        @Bindable var settings = appSettings

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configuration")
                        .font(.title2.weight(.semibold))
                    Text("Keyboard shortcuts, recording style, and general settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                // Settings Form
                Form {
                    // Recording Window Style
                    Section("Recording Window") {
                        Picker("Window Style", selection: $state.recordingWindowStyle) {
                            Text("Classic").tag(RecordingWindowStyle.classic)
                            Text("Mini").tag(RecordingWindowStyle.mini)
                            Text("None").tag(RecordingWindowStyle.none)
                        }
                        .pickerStyle(.radioGroup)

                        Text(windowStyleDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Keyboard Shortcuts
                    Section("Keyboard Shortcuts") {
                        HotkeyRecorderView(
                            label: "Toggle Recording",
                            requiredBinding: $state.toggleRecordingHotkey
                        )

                        HotkeyRecorderView(
                            label: "Cancel Recording",
                            binding: $state.cancelRecordingHotkey
                        )

                        HotkeyRecorderView(
                            label: "Push to Talk (hold)",
                            binding: $state.pushToTalkHotkey
                        )

                        HotkeyRecorderView(
                            label: "Enhance Recording",
                            binding: $state.enhanceRecordingHotkey
                        )

                        Text("Enhance: Records, transcribes, then polishes your text with AI before pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // General
                    Section("General") {
                        Toggle("Launch at Login", isOn: $state.launchAtLogin)

                        Text(
                            "Automatically start Parrot when you log in to your Mac."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // Enhance Mode (Azure OpenAI)
                    Section("Enhance Mode") {
                        TextField("Azure OpenAI Endpoint", text: $settings.enhanceEndpoint)
                            .textFieldStyle(.roundedBorder)

                        Text("e.g. https://your-resource.openai.azure.com/openai/v1")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        TextField("Model Deployment Name", text: $settings.enhanceModel)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Group {
                                if showApiKey {
                                    TextField("API Key", text: $apiKeyInput)
                                } else {
                                    SecureField("API Key", text: $apiKeyInput)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: apiKeyInput) { _, newValue in
                                settings.enhanceApiKey = newValue
                                appState.textEnhancer?.apiKey = newValue
                            }

                            Button {
                                showApiKey.toggle()
                            } label: {
                                Image(systemName: showApiKey ? "eye.slash" : "eye")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                        }

                        Text(
                            "API key is stored securely in macOS Keychain. Enhance mode uses Azure OpenAI to polish your transcription before pasting."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if !settings.enhanceEndpoint.isEmpty,
                           !settings.enhanceModel.isEmpty,
                           !settings.enhanceApiKey.isEmpty {
                            Label("Enhance mode configured", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            apiKeyInput = appSettings.enhanceApiKey
            // Sync current settings into the live TextEnhancer
            appState.textEnhancer?.configure(from: appSettings)
        }
        .onChange(of: appSettings.enhanceEndpoint) { _, _ in
            appState.textEnhancer?.endpoint = appSettings.enhanceEndpoint
        }
        .onChange(of: appSettings.enhanceModel) { _, _ in
            appState.textEnhancer?.model = appSettings.enhanceModel
        }
        // Persist hotkey changes and sync to the runtime HotkeyManager
        .onChange(of: appState.toggleRecordingHotkey) { _, newValue in
            appSettings.hotkeyBinding = newValue
            // Don't push broken keyCode:0 keyboard bindings
            if newValue.mouseButton != nil || newValue.keyCode != 0 {
                appState.hotkeyManager?.binding = AppState.toGlobalBinding(newValue)
            }
        }
        .onChange(of: appState.cancelRecordingHotkey) { _, newValue in
            appSettings.cancelHotkeyBinding = newValue
        }
        .onChange(of: appState.pushToTalkHotkey) { _, newValue in
            appSettings.pushToTalkBinding = newValue
        }
    }

    private var windowStyleDescription: String {
        switch appState.recordingWindowStyle {
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
    ConfigurationView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
