import AppKit
import SwiftUI

// MARK: - ModesView

/// The Modes tab: mode cards in the user's order, the active mode, and
/// adding, editing, reordering and deleting modes. [LLM]
///
/// Edits go through `ModeManager` (one file per mode); `appState.modes`
/// is kept equal to the manager's list so URL and recorder code that read
/// it stay current.
struct ModesView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @State private var editingMode: Mode?
    @State private var creatingMode: Mode?
    @State private var pendingDelete: Mode?

    private var manager: ModeManager? { appState.modeManager }
    private var modes: [Mode] { manager?.modes ?? appState.modes }
    private var selectedID: UUID? { manager?.selectedMode.id ?? appState.currentMode?.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if modes.isEmpty {
                emptyState
            } else {
                modeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .sheet(item: $editingMode) { mode in
            ModeEditSheet(mode: mode, onSave: save)
        }
        .sheet(item: $creatingMode) { mode in
            ModeEditSheet(mode: mode, isNew: true, onSave: add)
        }
        .confirmationDialog(
            "Delete this mode?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { mode in
            Button("Delete \(mode.name)", role: .destructive) { delete(mode) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The mode is removed from Parrot. A copy of its file stays in the modes folder under .deleted.")
        }
        .onAppear(perform: syncAppState)
        .onChange(of: manager?.modes) { _, _ in syncAppState() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Modes")
                    .font(.title2.weight(.semibold))
                Text("Each mode is a recipe: how Parrot listens, rewrites and pastes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            activeModePicker

            addModeMenu
        }
        .padding(20)
    }

    /// The active mode picker: the mode dictations use unless an app or
    /// site rule picks another.
    private var activeModePicker: some View {
        Picker("Active mode", selection: Binding(
            get: { selectedID ?? modes.first?.id ?? UUID() },
            set: { id in if let mode = modes.first(where: { $0.id == id }) { select(mode) } }
        )) {
            ForEach(modes) { mode in
                Label(mode.name, systemImage: ModePresets.iconName(for: mode)).tag(mode.id)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("The mode Parrot uses unless an app or website picks another")
    }

    private var addModeMenu: some View {
        Menu {
            ForEach(ModePresets.all, id: \.type) { preset in
                Button {
                    creatingMode = ModePresets.make(preset.type, key: manager?.uniqueKey(for: preset.key) ?? preset.key)
                } label: {
                    Label("\(preset.name): \(preset.description)", systemImage: preset.iconName)
                }
            }
        } label: {
            Label("Add Mode", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    // MARK: - List

    private var modeList: some View {
        List {
            Section {
                ForEach(modes) { mode in
                    modeRow(mode)
                }
                .onMove(perform: move)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Auto-switch: add apps or websites to a mode and Parrot uses it there.", systemImage: "arrow.triangle.branch")
                    Label("Drag modes to reorder them. Each mode can also have its own shortcut.", systemImage: "line.3.horizontal")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
        }
        .listStyle(.inset)
    }

    private func modeRow(_ mode: Mode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            Image(systemName: ModePresets.iconName(for: mode))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .font(.body.weight(.medium))
                    Text(ModePresets.preset(for: mode.type).name.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
                    if selectedID == mode.id {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .help("Active mode")
                    }
                }

                if !mode.description.isEmpty {
                    Text(mode.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                rowDetails(mode)
            }

            Spacer()

            if selectedID != mode.id {
                Button("Use") { select(mode) }
                    .buttonStyle(.borderless)
                    .help("Make this the active mode")
            }

            Button {
                editingMode = mode
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit mode")

            Button(role: .destructive) {
                pendingDelete = mode
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(modes.count <= 1)
            .help(modes.count <= 1 ? "Parrot needs at least one mode" : "Delete mode")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingMode = mode }
    }

    @ViewBuilder
    private func rowDetails(_ mode: Mode) -> some View {
        let apps = mode.appBundleIDs?.count ?? 0
        let sites = mode.activationSites.count
        HStack(spacing: 10) {
            if !ModePresets.usesLanguageModel(mode.type) {
                Label("No AI rewriting", systemImage: "waveform")
            } else if !mode.languageModelID.isEmpty {
                Label(mode.languageModelID, systemImage: "cpu")
            }
            if apps > 0 {
                Label("\(apps) app\(apps == 1 ? "" : "s")", systemImage: "app.badge")
            }
            if sites > 0 {
                Label("\(sites) site\(sites == 1 ? "" : "s")", systemImage: "globe")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Modes")
                .font(.title3.weight(.medium))
            Text("Add a mode to choose how Parrot rewrites what you say.")
                .font(.callout)
                .foregroundStyle(.secondary)
            addModeMenu
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func select(_ mode: Mode) {
        if let manager {
            manager.selectMode(mode)
            appState.currentMode = manager.selectedMode
        } else {
            appState.currentMode = mode
        }
    }

    private func save(_ mode: Mode) {
        guard let manager else {
            if let index = appState.modes.firstIndex(where: { $0.id == mode.id }) { appState.modes[index] = mode }
            return
        }
        manager.updateMode(mode)
        syncAppState()
    }

    private func add(_ mode: Mode) {
        guard let manager else {
            appState.modes.append(mode)
            return
        }
        manager.addMode(mode)
        syncAppState()
    }

    private func delete(_ mode: Mode) {
        guard let manager else {
            appState.modes.removeAll { $0.id == mode.id }
            return
        }
        manager.removeMode(id: mode.id)
        syncAppState()
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let manager else {
            appState.modes.move(fromOffsets: source, toOffset: destination)
            return
        }
        var keys = manager.modeOrder
        keys.move(fromOffsets: source, toOffset: destination)
        manager.setOrder(keys)
        syncAppState()
    }

    /// Mirrors the manager into AppState (a no-op write when equal).
    private func syncAppState() {
        guard let manager else { return }
        if appState.modes != manager.modes { appState.modes = manager.modes }
        if appState.currentMode != manager.selectedMode { appState.currentMode = manager.selectedMode }
    }
}

// MARK: - Mode Edit Sheet

/// Edits one mode as a draft; nothing is saved until Save. Sections owned by
/// other areas are embedded last, in a fixed order, and edit the same draft.
struct ModeEditSheet: View {
    let mode: Mode?
    let isNew: Bool
    let onSave: (Mode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    /// The mode being edited, so fields this sheet does not show (and the
    /// embedded sections' edits) survive a save.
    @State private var draft = Mode(name: "")
    @State private var showingActivation = false
    @State private var showingIcons = false

    init(mode: Mode?, isNew: Bool? = nil, onSave: @escaping (Mode) -> Void) {
        self.mode = mode
        self.isNew = isNew ?? (mode == nil)
        self.onSave = onSave
    }

    private var usesModel: Bool { ModePresets.usesLanguageModel(draft.type) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Mode" : "Edit Mode")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Form {
                detailsSection
                typeSection
                if usesModel {
                    languageModelSection
                    toneSection
                    instructionsSection
                    examplesSection
                    contextSection
                }
                activationSection

                // Sections owned by other areas, in this fixed order.
                VoiceModeSection(mode: $draft)
                AudioModeSection(mode: $draft)
                OutputModeSection(mode: $draft)
                ShortcutModeSection(mode: $draft)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isNew ? "Add" : "Save") {
                    var saved = draft
                    saved.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prompt = (draft.refinementPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.refinementPrompt = prompt.isEmpty ? nil : prompt
                    saved.appBundleIDs = (draft.appBundleIDs ?? []).isEmpty ? nil : draft.appBundleIDs
                    saved.promptExamples = draft.promptExamples.filter {
                        !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 600, height: 760)
        .onAppear {
            if let mode {
                draft = mode
            } else {
                draft = ModePresets.make(.custom, key: Mode.defaultKey(for: UUID()))
                draft.name = ""
            }
        }
        .sheet(isPresented: $showingActivation) {
            ActivationSheet(
                apps: Binding(get: { draft.appBundleIDs ?? [] }, set: { draft.appBundleIDs = $0 }),
                sites: $draft.activationSites
            )
        }
    }

    // MARK: - Details and Type

    private var detailsSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    showingIcons = true
                } label: {
                    Image(systemName: ModePresets.iconName(for: draft))
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Choose an icon")
                .popover(isPresented: $showingIcons) {
                    IconPicker(selection: $draft.iconName, defaultIcon: ModePresets.preset(for: draft.type).iconName)
                }

                TextField("Name", text: $draft.name)
            }
            TextField("Description", text: $draft.description)
        }
    }

    private var typeSection: some View {
        Section("Type") {
            Picker("Starts from", selection: $draft.type) {
                ForEach(ModePresets.all, id: \.type) { preset in
                    Label(preset.name, systemImage: preset.iconName).tag(preset.type)
                }
            }
            Text(ModePresets.preset(for: draft.type).description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Language Model

    @ViewBuilder
    private var languageModelSection: some View {
        Section("Language model") {
            if let appSettings {
                Picker("Model", selection: $draft.languageModelID) {
                    ForEach(LanguageModelCatalog.choices(settings: appSettings, including: draft.languageModelID)) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                Text(modelHelp(appSettings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Language models are set up under Models > Language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modelHelp(_ settings: AppSettings) -> String {
        if draft.languageModelID.isEmpty {
            return settings.refinement.refinementEnabled
                ? "Rewrites the transcript with the default model from Language Models."
                : "AI refinement is off in Language Models, so this mode pastes the transcript as spoken. Pick a model here to turn it on for this mode only."
        }
        return "This mode always rewrites with this model, even when AI refinement is off globally."
    }

    // MARK: - Tone

    private var toneSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tone")
                    Spacer()
                    Text(draft.tone?.displayName ?? "Not set")
                        .foregroundStyle(.secondary)
                    if draft.tone != nil {
                        Button("Reset") { draft.tone = nil }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                Slider(
                    value: Binding(
                        get: { Double((draft.tone ?? .balanced).sliderIndex) },
                        set: { draft.tone = Tone(sliderIndex: Int($0.rounded())) }
                    ),
                    in: 0...Double(Tone.sliderOrder.count - 1),
                    step: 1
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Casual").font(.caption)
                } maximumValueLabel: {
                    Text("Formal").font(.caption)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("You say: \(Tone.exampleInput)")
                        .foregroundStyle(.secondary)
                    Text("Parrot writes: \((draft.tone ?? .balanced).example)")
                }
                .font(.caption)
            }
        } footer: {
            Text("Controls how formal the cleaned text reads. Only casing, punctuation and word forms change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Instructions and Examples

    private var instructionsSection: some View {
        let builtIn = ModePresets.preset(for: draft.type).instruction
        let prompt = Binding(get: { draft.refinementPrompt ?? "" }, set: { draft.refinementPrompt = $0 })
        return Section("Instructions") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: prompt)
                    .font(.callout)
                    .frame(minHeight: 90)
                if prompt.wrappedValue.isEmpty {
                    Text(builtIn == nil
                         ? "Describe how Parrot should rewrite what you say, for example \"Format as a friendly email\"."
                         : "Using the built-in instruction for this type. Type here to replace it.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            if let builtIn, prompt.wrappedValue.isEmpty {
                DisclosureGroup("Built-in instruction") {
                    Text(builtIn)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Start from this text") { draft.refinementPrompt = builtIn }
                        .font(.caption)
                }
            }
            if builtIn == nil {
                Text("Leave empty for Parrot's standard cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var examplesSection: some View {
        Section {
            ForEach($draft.promptExamples) { $example in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("What you say", text: $example.input, axis: .vertical)
                            .lineLimit(1...4)
                        TextField("What you want the AI to write", text: $example.output, axis: .vertical)
                            .lineLimit(1...6)
                    }
                    Button {
                        draft.promptExamples.removeAll { $0.id == example.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove example")
                }
                .padding(.vertical, 2)
            }
            Button {
                draft.promptExamples.append(PromptExample(input: "", output: ""))
            } label: {
                Label("Add Example", systemImage: "plus")
            }
        } header: {
            Text("Examples")
        } footer: {
            Text(ModePresets.builtInExamples(for: draft).isEmpty
                 ? "Pairs of what you say and what you want. They show the AI your style."
                 : "Pairs of what you say and what you want. This type's built-in examples are used too while the instructions are empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Context

    private var contextSection: some View {
        Section {
            Toggle(isOn: $draft.contextFromActiveApplication) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Application context")
                    Text("The app and field you are typing into, the website in a browser, and the time, time zone and computer name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $draft.contextFromClipboard) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard")
                    Text("Text you copied in the 3 seconds before you started recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $draft.contextFromSelection) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected text")
                    Text("Text you had selected when you started recording. Call it \"selected text\" in your instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = contextNote {
                Label(note, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Context")
        }
    }

    /// Why some context will not be sent, if anything blocks it.
    private var contextNote: String? {
        guard let appSettings else { return nil }
        let refinement = appSettings.refinement
        if !refinement.destinationAwareRefinement {
            return "Context is turned off for every mode in Models > Language."
        }
        let wantsText = draft.contextFromClipboard || draft.contextFromSelection || draft.contextFromActiveApplication
        if wantsText, refinement.contextLocalOnly,
           !LanguageModelCatalog.isLocal(draft.languageModelID, settings: appSettings)
        {
            return "This mode uses a cloud model and \"Keep field content on this Mac\" is on, so selected text, clipboard and field text stay on this Mac."
        }
        return nil
    }

    // MARK: - Activation

    private var activationSection: some View {
        Section {
            let apps = draft.appBundleIDs ?? []
            if apps.isEmpty && draft.activationSites.isEmpty {
                Text("No apps or websites yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    AppIconView(bundleID: bundleID)
                        .frame(width: 18, height: 18)
                    Text(AppDirectory.displayName(for: bundleID))
                    Spacer()
                    Button {
                        draft.appBundleIDs = apps.filter { $0 != bundleID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(draft.activationSites, id: \.self) { site in
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                    Text(site)
                    Spacer()
                    Button {
                        draft.activationSites.removeAll { $0 == site }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add Apps and Sites...") { showingActivation = true }
        } header: {
            Text("Activate for apps")
        } footer: {
            Text("Parrot switches to this mode when you dictate into these apps or websites. A website match wins over an app match.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Activation Sheet

/// Picks apps, website addresses and whole categories for a mode.
struct ActivationSheet: View {
    @Binding var apps: [String]
    @Binding var sites: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var installed: [AppDirectory.Item] = []

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The search as a website, when it looks like one.
    private var typedSite: String? {
        guard query.contains("."), !query.contains(" "), let site = ModeActivation.normalizedSite(query) else { return nil }
        return sites.contains(site) ? nil : site
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Apps and Sites")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            TextField("App name or website address", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            List {
                if let site = typedSite {
                    Button {
                        sites.append(site)
                        search = ""
                    } label: {
                        Label("Add website \(site)", systemImage: "globe")
                    }
                }

                Section("Categories") {
                    ForEach(categories) { category in
                        HStack {
                            Label(category.name, systemImage: category.symbol)
                            Spacer()
                            Button(isAdded(category) ? "Added" : "Add") { add(category) }
                                .disabled(isAdded(category))
                        }
                        .help(categoryHelp(category))
                    }
                }

                Section("Apps") {
                    ForEach(filteredApps) { app in
                        HStack(spacing: 8) {
                            AppIconView(bundleID: app.bundleID)
                                .frame(width: 18, height: 18)
                            Text(app.name)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { apps.contains(app.bundleID) },
                                set: { on in setApp(app.bundleID, included: on) }
                            ))
                            .labelsHidden()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 460, height: 560)
        .task {
            installed = await Task.detached(priority: .userInitiated) { AppDirectory.installedApps() }.value
        }
    }

    private var categories: [ActivationCategory] {
        let all = AppCatalog.activationCategories
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredApps: [AppDirectory.Item] {
        guard !query.isEmpty else { return installed }
        return installed.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    /// Installed apps of the category plus its sites.
    private func members(of category: ActivationCategory) -> (apps: [String], sites: [String]) {
        let installedIDs = Set(installed.map(\.bundleID))
        return (category.bundleIDs.filter { installedIDs.contains($0) }, category.sites)
    }

    private func setApp(_ bundleID: String, included: Bool) {
        if included {
            if !apps.contains(bundleID) { apps.append(bundleID) }
        } else {
            apps.removeAll { $0 == bundleID }
        }
    }

    private func isAdded(_ category: ActivationCategory) -> Bool {
        let (memberApps, memberSites) = members(of: category)
        guard !memberApps.isEmpty || !memberSites.isEmpty else { return true }
        return memberApps.allSatisfy { apps.contains($0) } && memberSites.allSatisfy { sites.contains($0) }
    }

    private func add(_ category: ActivationCategory) {
        let (memberApps, memberSites) = members(of: category)
        for id in memberApps where !apps.contains(id) { apps.append(id) }
        for site in memberSites where !sites.contains(site) { sites.append(site) }
    }

    private func categoryHelp(_ category: ActivationCategory) -> String {
        let (memberApps, memberSites) = members(of: category)
        let names = memberApps.map(AppDirectory.displayName(for:)) + memberSites
        return names.isEmpty ? "Nothing from this category is installed." : names.joined(separator: ", ")
    }
}

// MARK: - Icon Picker

/// A grid of SF Symbols for a mode's icon.
struct IconPicker: View {
    @Binding var selection: String
    let defaultIcon: String

    private static let symbols = [
        "sparkles", "waveform", "message.fill", "envelope.fill", "note.text", "person.3.fill",
        "slider.horizontal.3", "text.bubble.fill", "bubble.left.and.bubble.right.fill", "doc.text.fill",
        "pencil", "highlighter", "list.bullet", "checklist", "terminal.fill",
        "chevron.left.forwardslash.chevron.right", "graduationcap.fill", "briefcase.fill", "book.fill",
        "lightbulb.fill", "brain.head.profile", "globe", "translate", "quote.bubble.fill", "megaphone.fill",
        "heart.fill", "star.fill", "bolt.fill", "leaf.fill", "flame.fill", "hammer.fill", "wand.and.stars",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        selection = symbol
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selection == symbol ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                }
            }
            Button {
                selection = ""
            } label: {
                Label("Use the type's icon", systemImage: defaultIcon)
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
        }
        .padding(12)
    }
}

// MARK: - Apps on This Mac

/// Installed apps for the activation sheet, and names and icons by bundle id.
enum AppDirectory {
    struct Item: Identifiable, Hashable, Sendable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Apps in /Applications (one folder deep), /System/Applications and its
    /// Utilities, and ~/Applications, sorted by name.
    static func installedApps() -> [Item] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var bundles: [URL] = []
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    bundles.append(entry)
                } else if root.path == "/Applications", entry.hasDirectoryPath,
                          let nested = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
                {
                    bundles.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }
        var seen = Set<String>()
        var items: [Item] = []
        for url in bundles {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            items.append(Item(bundleID: id, name: name))
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url)
        {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}

/// An app's icon, or a placeholder when it is not installed.
struct AppIconView: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ModesView()
        .environment(AppState())
        .frame(width: 600, height: 500)
}
