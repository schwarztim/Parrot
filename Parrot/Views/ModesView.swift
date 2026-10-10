import AppKit
import SwiftUI

struct ModesView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

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

                if let apps = mode.appBundleIDs, !apps.isEmpty {
                    Label("\(apps.count) app\(apps.count == 1 ? "" : "s")", systemImage: "app.badge")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
    @State private var refinementPrompt: String = ""
    @State private var appBundleIDs: [String] = []
    /// The mode being edited, so fields this sheet does not show (and the
    /// embedded sections' edits) survive a save.
    @State private var draft = Mode(name: "")

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

                Section("Auto-select in apps") {
                    ForEach(appBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            appIcon(for: bundleID)
                                .frame(width: 18, height: 18)
                            Text(appDisplayName(for: bundleID))
                            Spacer()
                            Button {
                                appBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Menu("Add App...") {
                        ForEach(runningApps(), id: \.bundleID) { app in
                            Button(app.name) { addApp(app.bundleID) }
                        }
                        Divider()
                        Button("Choose from Applications...") { chooseApp() }
                    }

                    Text("Dictating into these apps automatically uses this mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AI Refinement") {
                    TextEditor(text: $refinementPrompt)
                        .font(.callout)
                        .frame(minHeight: 60)

                    Text("Directive used when refining transcripts in this mode, e.g. \"Format as a professional email\". Leave empty for the default cleanup directive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Sections owned by other areas, in this fixed order.
                VoiceModeSection(mode: $draft)
                AudioModeSection(mode: $draft)
                OutputModeSection(mode: $draft)
                ShortcutModeSection(mode: $draft)
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
                    let trimmedPrompt = refinementPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    var savedMode = draft
                    savedMode.name = name
                    savedMode.description = description
                    savedMode.isDefault = mode?.isDefault ?? false
                    savedMode.refinementPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
                    savedMode.appBundleIDs = appBundleIDs.isEmpty ? nil : appBundleIDs
                    onSave(savedMode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 450, height: 540)
        .onAppear {
            if let mode = mode {
                draft = mode
                name = mode.name
                description = mode.description
                refinementPrompt = mode.refinementPrompt ?? ""
                appBundleIDs = mode.appBundleIDs ?? []
            }
        }
    }

    // MARK: - App Assignment Helpers

    private struct RunningApp { let name: String; let bundleID: String }

    private func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return RunningApp(name: name, bundleID: id)
            }
            .filter { !appBundleIDs.contains($0.bundleID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addApp(_ bundleID: String) {
        guard !appBundleIDs.contains(bundleID) else { return }
        appBundleIDs.append(bundleID)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let id = Bundle(url: url)?.bundleIdentifier {
            addApp(id)
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?
            .object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleID
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ModesView()
        .environment(AppState())
        .frame(width: 500, height: 500)
}
