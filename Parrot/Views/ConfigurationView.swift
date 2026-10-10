import SwiftUI

struct ConfigurationView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var showApiKey = false
    @State private var isTestingConnection = false
    @State private var testResult: TestResult?
    @State private var ollamaModels: [String] = []
    @State private var isLoadingModels = false

    private enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        @Bindable var state = appState
        @Bindable var recorder = appSettings.recorder
        @Bindable var hotkeys = appSettings.hotkeys
        @Bindable var refinement = appSettings.refinement

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

                    // Keyboard Shortcuts
                    Section("Keyboard Shortcuts") {
                        HotkeyRecorderView(
                            label: "Toggle Recording",
                            requiredBinding: $hotkeys.hotkeyBinding
                        )

                        HotkeyRecorderView(
                            label: "Cancel Recording",
                            binding: $hotkeys.cancelHotkeyBinding
                        )

                        HotkeyRecorderView(
                            label: "Push to Talk (hold)",
                            binding: $hotkeys.pushToTalkBinding
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

                    // AI Refinement
                    Section("AI Refinement") {
                        Toggle("Refine transcripts with AI", isOn: $refinement.refinementEnabled)

                        Text(
                            "Sends the transcript to the chosen LLM to fix dictation errors, punctuation, and formatting before pasting. On any failure the raw transcript is pasted instead."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Picker("Provider", selection: $refinement.refinementProvider) {
                            ForEach(RefinementProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .onChange(of: refinement.refinementProvider) { _, _ in
                            testResult = nil
                        }

                        Toggle("Destination-aware refinement", isOn: $refinement.destinationAwareRefinement)
                        Text("Adapts tone and format to the app and field you dictate into (email style in Mail, casual in chat, no rewriting in code). Reads only local Accessibility data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if refinement.destinationAwareRefinement, refinement.refinementProvider != .localServer {
                            Toggle("Keep field content on-device only", isOn: $refinement.contextLocalOnly)
                            Text("When on, the surrounding field text is never sent to the cloud provider; only the app name and field type are.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        providerFields(refinement: $refinement)

                        HStack {
                            Button {
                                testConnection()
                            } label: {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Test Connection")
                                }
                            }
                            .disabled(isTestingConnection || !RefinementService.isConfigured(appSettings))

                            switch testResult {
                            case .success:
                                Label("Connection works", systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                            case .failure(let message):
                                Label(message, systemImage: "xmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            case nil:
                                EmptyView()
                            }
                        }

                        if RefinementService.isConfigured(appSettings) {
                            Label("Refinement configured", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }

                        Text("API keys are stored securely in the macOS Keychain, one entry per provider.")
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
        // The bindings save themselves; sync the dictation one to the
        // runtime HotkeyManager.
        .onChange(of: appSettings.hotkeys.hotkeyBinding) { _, newValue in
            // Don't push broken keyCode:0 keyboard bindings
            if newValue.mouseButton != nil || newValue.keyCode != 0 {
                appState.hotkeyManager?.binding = AppState.toGlobalBinding(newValue)
            }
        }
    }

    // MARK: - Provider Fields

    @ViewBuilder
    private func providerFields(refinement: Bindable<RefinementSettings>) -> some View {
        @Bindable var credentials = appSettings.credentials
        switch appSettings.refinement.refinementProvider {
        case .localServer:
            TextField("Base URL", text: refinement.localServerBaseURL)
                .textFieldStyle(.roundedBorder)
            Text("OpenAI-compatible server. Ollama: http://localhost:11434/v1, LM Studio: http://localhost:1234/v1")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                TextField("Model", text: refinement.localServerModel)
                    .textFieldStyle(.roundedBorder)

                Button {
                    loadOllamaModels()
                } label: {
                    if isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("List Models")
                    }
                }
                .disabled(isLoadingModels)
                .help("Lists installed models from an Ollama server via /api/tags")
            }

            if !ollamaModels.isEmpty {
                Picker("Installed Models", selection: refinement.localServerModel) {
                    ForEach(ollamaModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            keyField("API Key (optional)", text: $credentials.localServerKey)

        case .openAI:
            TextField("Model", text: refinement.openAIModel)
                .textFieldStyle(.roundedBorder)
            Text("e.g. gpt-4o-mini")
                .font(.caption)
                .foregroundStyle(.tertiary)
            keyField("API Key", text: $credentials.openAIKey)

        case .azureOpenAI:
            TextField("Endpoint", text: refinement.azureOpenAIEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("e.g. https://your-resource.openai.azure.com")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Deployment Name", text: refinement.azureOpenAIDeployment)
                .textFieldStyle(.roundedBorder)
            TextField("API Version", text: refinement.azureOpenAIAPIVersion)
                .textFieldStyle(.roundedBorder)
            keyField("API Key", text: $credentials.azureOpenAIKey)

        case .anthropic:
            TextField("Model", text: refinement.anthropicModel)
                .textFieldStyle(.roundedBorder)
            Text("claude-haiku-4-5 (fast), claude-sonnet-5, or claude-opus-4-8")
                .font(.caption)
                .foregroundStyle(.tertiary)
            keyField("API Key", text: $credentials.anthropicKey)
        }
    }

    private func keyField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Group {
                if showApiKey {
                    TextField(label, text: text)
                } else {
                    SecureField(label, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                showApiKey.toggle()
            } label: {
                Image(systemName: showApiKey ? "eye.slash" : "eye")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Actions

    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        Task {
            do {
                _ = try await RefinementService.refine(
                    "testing testing one two three",
                    modePrompt: nil,
                    settings: appSettings
                )
                testResult = .success
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTestingConnection = false
        }
    }

    private func loadOllamaModels() {
        isLoadingModels = true
        Task {
            do {
                ollamaModels = try await OllamaAPI.listModels(baseURL: appSettings.refinement.localServerBaseURL)
                if ollamaModels.isEmpty {
                    testResult = .failure("No models installed on the server.")
                }
            } catch {
                ollamaModels = []
                testResult = .failure(error.localizedDescription)
            }
            isLoadingModels = false
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
    ConfigurationView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
