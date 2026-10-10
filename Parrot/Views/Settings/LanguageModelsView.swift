import SwiftUI

/// Language models: the default provider, keys, context sharing and
/// models added with your own key. [LLM]
///
/// Shown as the Language segment of the Models tab. Keys go only through
/// `ProviderCredentials` (the Keychain); nothing here stores a secret.
struct LanguageModelsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppState.self) private var appState: AppState?

    @State private var showApiKey = false
    @State private var testOutcome: ConnectionTester.Outcome?
    @State private var isTesting = false
    @State private var ollamaModels: [String] = []
    @State private var isLoadingModels = false
    @State private var contactsNote: String?

    @State private var newModel = CustomLanguageModel(name: "", provider: .openAICompatible, modelID: "")
    @State private var customTests: [String: ConnectionTester.Outcome] = [:]
    @State private var pendingRemoval: CustomLanguageModel?

    var body: some View {
        @Bindable var refinement = appSettings.refinement

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language Models")
                        .font(.title2.weight(.semibold))
                    Text("Rewrite your transcripts with the model you choose")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    defaultModelSection(refinement: $refinement)
                    contextSection(refinement: $refinement)
                    customModelsSection
                    addModelSection
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .confirmationDialog(
            "Remove this model?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { model in
            Button("Remove \(model.name)", role: .destructive) { remove(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            let count = modesUsing(model.languageModelID).count
            Text(count == 0
                 ? "No mode uses it."
                 : "\(count) mode\(count == 1 ? "" : "s") use\(count == 1 ? "s" : "") it and will go back to the default model.")
        }
    }

    // MARK: - Default Model

    private func defaultModelSection(refinement: Bindable<RefinementSettings>) -> some View {
        Section {
            Toggle("Refine transcripts with AI", isOn: refinement.refinementEnabled)
            Text("Sends the transcript to the chosen model to fix dictation errors, punctuation and formatting before pasting. Modes that pick their own model always use it. On any failure the raw transcript is pasted instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Default provider", selection: refinement.refinementProvider) {
                ForEach(RefinementProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .onChange(of: appSettings.refinement.refinementProvider) { _, _ in testOutcome = nil }

            providerFields(refinement: refinement)

            HStack {
                Button {
                    test(languageModelID: "") { testOutcome = $0 }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || !RefinementService.isConfigured(appSettings))
                .help("Lists the provider's models; no text is generated")

                if let testOutcome {
                    outcomeLabel(testOutcome)
                } else if RefinementService.isConfigured(appSettings) {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Default model")
        } footer: {
            Text("API keys are stored in the macOS Keychain, one entry per provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerFields(refinement: Bindable<RefinementSettings>) -> some View {
        switch appSettings.refinement.refinementProvider {
        case .localServer:
            TextField("Base URL", text: refinement.localServerBaseURL)
                .textFieldStyle(.roundedBorder)
            Text("OpenAI-compatible server on this Mac. Ollama: http://localhost:11434/v1, LM Studio: http://localhost:1234/v1")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                TextField("Model", text: refinement.localServerModel)
                    .textFieldStyle(.roundedBorder)
                Button {
                    loadOllamaModels()
                } label: {
                    if isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("List Models")
                    }
                }
                .disabled(isLoadingModels)
                .help("Lists installed models from an Ollama server via /api/tags")
            }
            if !ollamaModels.isEmpty {
                Picker("Installed Models", selection: refinement.localServerModel) {
                    ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                }
            }
            keyField("API Key (optional)", for: .localServer)

        case .openAI:
            modelField(refinement.openAIModel, hint: "For example gpt-4o-mini")
            keyField("API Key", for: .openAI)

        case .azureOpenAI:
            TextField("Endpoint", text: refinement.azureOpenAIEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("For example https://your-resource.openai.azure.com")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Deployment Name", text: refinement.azureOpenAIDeployment)
                .textFieldStyle(.roundedBorder)
            TextField("API Version", text: refinement.azureOpenAIAPIVersion)
                .textFieldStyle(.roundedBorder)
            keyField("API Key", for: .azureOpenAI)

        case .anthropic:
            modelField(refinement.anthropicModel, hint: "claude-haiku-4-5 (fast), claude-sonnet-5, or claude-opus-4-8")
            keyField("API Key", for: .anthropic)

        case .groq:
            modelField(refinement.groqModel, hint: "For example llama-3.3-70b-versatile or openai/gpt-oss-20b")
            keyField("API Key", for: .groq)

        case .gemini:
            modelField(refinement.geminiModel, hint: "For example gemini-2.5-flash")
            keyField("API Key", for: .gemini)

        case .deepseek:
            modelField(refinement.deepseekModel, hint: "deepseek-chat, or deepseek-reasoner (its reasoning is removed)")
            keyField("API Key", for: .deepseek)

        case .openAICompatible:
            TextField("Base URL", text: refinement.compatibleBaseURL)
                .textFieldStyle(.roundedBorder)
            Text("Any server with an OpenAI-style /chat/completions endpoint, including the version path. Addresses on this Mac count as local.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            modelField(refinement.compatibleModel, hint: "The model name the server expects")
            keyField("API Key (optional)", for: .openAICompatible)
        }
    }

    private func modelField(_ text: Binding<String>, hint: String) -> some View {
        Group {
            TextField("Model", text: text)
                .textFieldStyle(.roundedBorder)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func keyField(_ label: String, for id: ProviderID) -> some View {
        let credentials = appSettings.credentials
        let text = Binding(get: { credentials.key(for: id) }, set: { credentials.editKey($0, for: id) })
        return VStack(alignment: .leading, spacing: 4) {
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
                .help(showApiKey ? "Hide keys" : "Show keys")
            }
            if credentials.unreadable.contains(id) {
                Text("The saved key could not be read from the Keychain. Enter it again to use this provider.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Context

    private func contextSection(refinement: Bindable<RefinementSettings>) -> some View {
        Section {
            Toggle("Send context to language models", isOn: refinement.destinationAwareRefinement)
            Text("Lets modes include the app you are typing into, selected text, recent clipboard and system details, as each mode's context switches allow. Turn off to send only the transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Keep field content on this Mac", isOn: refinement.contextLocalOnly)
                .disabled(!appSettings.refinement.destinationAwareRefinement)
            Text("With cloud models, selected text, clipboard and the text around the cursor are never sent, and website addresses are cut to the site name. Local models still see everything.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include my contact card", isOn: Binding(
                get: { appSettings.refinement.includeContactCard },
                set: { setContactCard($0) }
            ))
            .disabled(!appSettings.refinement.destinationAwareRefinement)
            Text("Adds your name, email and phone number from the Contacts \"Me\" card in modes with application context on, so the AI can sign messages and spell your name. This is sent to cloud models too.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let contactsNote {
                Text(contactsNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Context")
        }
    }

    // MARK: - Custom Models

    @ViewBuilder
    private var customModelsSection: some View {
        let models = appSettings.refinement.customModels
        if !models.isEmpty {
            Section("Your models") {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).font(.body.weight(.medium))
                                Text("\(model.provider.displayName): \(model.modelID)\(model.baseURL.isEmpty ? "" : " at \(model.baseURL)")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            let used = modesUsing(model.languageModelID).count
                            if used > 0 {
                                Text("\(used) mode\(used == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Test") {
                                test(languageModelID: model.languageModelID) { customTests[model.id] = $0 }
                            }
                            Button("Use in All Modes") { useEverywhere(model) }
                                .disabled(appState?.modeManager == nil)
                                .help("Every mode except Voice uses this model")
                            Button("Remove", role: .destructive) { pendingRemoval = model }
                            if let outcome = customTests[model.id] {
                                outcomeLabel(outcome)
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var addModelSection: some View {
        Section {
            TextField("Name", text: $newModel.name, prompt: Text("For example Fast Groq"))
            Picker("Provider", selection: $newModel.provider) {
                ForEach(RefinementProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            TextField("Model ID", text: $newModel.modelID, prompt: Text("The provider's model name"))
            if newModel.provider == .openAICompatible || newModel.provider == .localServer || newModel.provider == .azureOpenAI {
                TextField("API URL", text: $newModel.baseURL, prompt: Text(baseURLPrompt(for: newModel.provider)))
            } else {
                TextField("API URL (optional)", text: $newModel.baseURL, prompt: Text(newModel.provider.defaultBaseURL ?? ""))
            }
            keyField(newModel.provider.requiresKey ? "API Key" : "API Key (optional)", for: newModel.provider.credential)
            Text("The key is shared by every \(newModel.provider.displayName) model.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add Model") { addModel() }
                .disabled(newModel.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || newModel.modelID.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Bring your own key")
        } footer: {
            Text("Connect straight to a provider with your own API key. Each mode picks its model in Modes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func baseURLPrompt(for provider: RefinementProvider) -> String {
        switch provider {
        case .azureOpenAI: return "https://your-resource.openai.azure.com"
        case .localServer: return "http://localhost:11434/v1"
        default: return "http://localhost:1234/v1"
        }
    }

    // MARK: - Shared Pieces

    private func outcomeLabel(_ outcome: ConnectionTester.Outcome) -> some View {
        Group {
            switch outcome {
            case .success:
                Label(outcome.message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Label(outcome.message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .font(.callout)
    }

    private func modesUsing(_ languageModelID: String) -> [Mode] {
        appState?.modeManager?.modes(usingLanguageModel: languageModelID) ?? []
    }

    // MARK: - Actions

    private func test(languageModelID: String, report: @escaping (ConnectionTester.Outcome) -> Void) {
        isTesting = true
        Task {
            let outcome = await ConnectionTester.test(languageModelID: languageModelID, settings: appSettings)
            report(outcome)
            isTesting = false
        }
    }

    private func addModel() {
        var model = newModel
        model.name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        model.baseURL = model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model.id = UUID().uuidString.lowercased()
        appSettings.refinement.customModels.append(model)
        newModel = CustomLanguageModel(name: "", provider: model.provider, modelID: "")
    }

    private func remove(_ model: CustomLanguageModel) {
        appState?.modeManager?.clearLanguageModel(model.languageModelID)
        syncModes()
        appSettings.refinement.customModels.removeAll { $0.id == model.id }
        customTests[model.id] = nil
    }

    private func useEverywhere(_ model: CustomLanguageModel) {
        appState?.modeManager?.useLanguageModelEverywhere(model.languageModelID)
        syncModes()
    }

    /// Keeps AppState's copy of the modes equal to the manager's. Writes
    /// `currentMode` only when it differs: a write also moves a recording
    /// in progress to that mode, which a model change is not.
    private func syncModes() {
        guard let appState, let manager = appState.modeManager else { return }
        if appState.modes != manager.modes { appState.modes = manager.modes }
        if appState.currentMode != manager.selectedMode { appState.currentMode = manager.selectedMode }
    }

    private func setContactCard(_ on: Bool) {
        contactsNote = nil
        guard on else {
            appSettings.refinement.includeContactCard = false
            return
        }
        appSettings.refinement.includeContactCard = true
        guard let contacts = appState?.services.context.contacts else { return }
        if !ContactCardReader.canRequestAccess && !ContactCardReader.isAuthorized {
            contactsNote = "Parrot cannot ask for Contacts access in this build, so your account name is used instead."
            return
        }
        Task {
            let granted = await contacts.requestAccess()
            if !granted {
                contactsNote = "Contacts access was not granted, so your account name is used instead. You can allow it in System Settings > Privacy & Security > Contacts."
            }
        }
    }

    private func loadOllamaModels() {
        isLoadingModels = true
        Task {
            do {
                ollamaModels = try await OllamaAPI.listModels(baseURL: appSettings.refinement.localServerBaseURL)
                if ollamaModels.isEmpty {
                    testOutcome = .failure("No models installed on the server.")
                }
            } catch {
                ollamaModels = []
                testOutcome = .failure(error.localizedDescription)
            }
            isLoadingModels = false
        }
    }
}

#Preview {
    LanguageModelsView()
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
