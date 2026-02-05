import SwiftUI

struct ModesView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddSheet = false
    @State private var editingMode: Mode?
    @State private var selectedModeID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Mode List
            if appState.modes.isEmpty {
                emptyState
            } else {
                modeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .sheet(isPresented: $showingAddSheet) {
            ModeEditSheet(
                mode: nil,
                onSave: { newMode in
                    appState.modes.append(newMode)
                }
            )
        }
        .sheet(item: $editingMode) { mode in
            ModeEditSheet(
                mode: mode,
                onSave: { updatedMode in
                    if let index = appState.modes.firstIndex(where: { $0.id == updatedMode.id }) {
                        appState.modes[index] = updatedMode
                    }
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Modes")
                    .font(.title2.weight(.semibold))
                Text("Configure voice transcription modes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingAddSheet = true
            } label: {
                Label("Add Mode", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(20)
    }

    // MARK: - Mode List

    private var modeList: some View {
        List(selection: $selectedModeID) {
            // Default mode pinned at top
            if let defaultMode = appState.modes.first(where: { $0.isDefault }) {
                Section("Default") {
                    modeRow(defaultMode)
                }
            }

            // Other modes
            let otherModes = appState.modes.filter { !$0.isDefault }
            if !otherModes.isEmpty {
                Section("Custom") {
                    ForEach(otherModes) { mode in
                        modeRow(mode)
                    }
                    .onDelete { indexSet in
                        let otherModeIDs = otherModes.map(\.id)
                        for index in indexSet {
                            let idToRemove = otherModeIDs[index]
                            appState.modes.removeAll { $0.id == idToRemove }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func modeRow(_ mode: Mode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .font(.body.weight(.medium))

                    if mode.isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor)
                            )
                    }

                    if appState.currentMode?.id == mode.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                if !mode.description.isEmpty {
                    Text(mode.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    Label(mode.voiceModelVersion, systemImage: "cpu")
                    Label(mode.language, systemImage: "globe")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Edit button
            Button {
                editingMode = mode
            } label: {
                Image(systemName: "pencil")
                    .font(.callout)
            }
            .buttonStyle(.borderless)

            // Delete button (not for default mode)
            if !mode.isDefault {
                Button(role: .destructive) {
                    appState.modes.removeAll { $0.id == mode.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .tag(mode.id)
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
            Text("Add a mode to customize your transcription settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Mode") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Mode Edit Sheet

struct ModeEditSheet: View {
    let mode: Mode?
    let onSave: (Mode) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var voiceModelVersion: String = "v3"
    @State private var language: String = "auto"

    private let availableLanguages = [
        "English", "Spanish", "French", "German", "Italian",
        "Portuguese", "Dutch", "Polish", "Russian", "Chinese",
        "Japanese", "Korean", "Arabic", "Hindi", "Turkish",
        "Vietnamese", "Thai", "Indonesian", "Malay", "Swedish",
        "Norwegian", "Danish", "Finnish", "Czech", "Ukrainian",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                Text(mode == nil ? "New Mode" : "Edit Mode")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            // Form
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)
                }

                Section("Voice Settings") {
                    Picker("Voice Model", selection: $voiceModelVersion) {
                        Text("v3").tag("v3")
                    }

                    Picker("Language", selection: $language) {
                        Text("Auto Detect").tag("auto")
                        ForEach(availableLanguages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode == nil ? "Add" : "Save") {
                    let savedMode = Mode(
                        id: mode?.id ?? UUID(),
                        name: name,
                        description: description,
                        voiceModelVersion: voiceModelVersion,
                        language: language,
                        isDefault: mode?.isDefault ?? false
                    )
                    onSave(savedMode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 450, height: 400)
        .onAppear {
            if let mode = mode {
                name = mode.name
                description = mode.description
                voiceModelVersion = mode.voiceModelVersion
                language = mode.language
            }
        }
    }
}

#Preview {
    ModesView()
        .environment(AppState())
        .frame(width: 500, height: 500)
}
