import AppKit
import SwiftUI

/// Past recordings grouped by day, newest first, with full-text search,
/// paging, multi-select, bulk delete and a detail pane. [DATA]
struct HistoryView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    @State private var model = HistoryListModel()
    @State private var playback = AudioPlaybackService()
    @State private var showSettings = false
    @State private var confirmBulkDelete = false
    @State private var copiedSelection = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            model.store = appState.historyStore
            model.reload()
        }
        .onDisappear { playback.stop() }
        .onChange(of: appState.lastTranscription) { _, _ in model.reload() }
        .task(id: model.query) {
            // Debounce search input.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            model.reload()
        }
        .confirmationDialog(
            "Are you sure you want to delete \(model.selectionCount) recordings? This action cannot be undone.",
            isPresented: $confirmBulkDelete
        ) {
            Button("Delete \(model.selectionCount)", role: .destructive) {
                let result = model.deleteSelection()
                playback.stopIfPlaying(result.ids)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    HistorySettingsPanel(onRetentionApplied: { model.reload() })
                        .environment(appState)
                        .environment(appSettings)
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $model.query)
                        .textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(.controlBackgroundColor)))
                .frame(maxWidth: 280)

                Spacer()

                if model.isMultiSelect {
                    Text(model.isSelectAllMode ? "All \(model.selectionCount) selected" : "\(model.selectionCount) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Select All") { model.selectAllMatching() }
                        .disabled(model.totalCount == 0)
                    Button {
                        copySelection()
                    } label: {
                        Label(copiedSelection ? "Copied" : "Copy", systemImage: copiedSelection ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(model.selectionCount == 0)
                    Button(role: .destructive) {
                        confirmBulkDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(model.selectionCount == 0)
                    Button("Done") { model.isMultiSelect = false }
                } else {
                    Button("Select") { model.isMultiSelect = true }
                        .disabled(model.entries.isEmpty)
                }
            }
        }
        .padding(20)
    }

    private var subtitle: String {
        if !appSettings.history.historyEnabled { return "History is off" }
        let count = model.totalCount
        if !model.loadedQuery.isEmpty { return "\(count) \(count == 1 ? "match" : "matches")" }
        return "\(count) \(count == 1 ? "recording" : "recordings"), kept \(RetentionOption.label(forDays: appSettings.history.historyRetentionDays).lowercased())"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.store == nil {
            emptyState(icon: "exclamationmark.triangle", title: "History is unavailable", message: "The history database could not be opened.")
        } else if model.entries.isEmpty {
            if !appSettings.history.historyEnabled && model.loadedQuery.isEmpty {
                emptyState(icon: "nosign", title: "History is off", message: "Turn on Save history in Settings to keep a searchable record of your dictations.")
            } else {
                emptyState(icon: model.loadedQuery.isEmpty ? "clock" : "magnifyingglass", title: "No recordings found.", message: model.loadedQuery.isEmpty ? "Your dictations will appear here." : "Try a different search.")
            }
        } else {
            HSplitView {
                list
                    .frame(minWidth: 260, idealWidth: 340)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) {
            ForEach(model.groups) { group in
                Section(HistoryGrouping.title(for: group.day)) {
                    ForEach(group.entries) { entry in
                        HistoryRowView(
                            entry: entry,
                            query: model.loadedQuery,
                            isMultiSelect: model.isMultiSelect,
                            isChecked: model.isSelectAllMode || model.checked.contains(entry.id),
                            onToggleChecked: { model.toggleChecked(entry.id) }
                        )
                        .tag(entry.id)
                        .onAppear { model.loadMoreIfNeeded(after: entry) }
                    }
                }
            }
            if model.hasMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .onAppear { model.loadMore() }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selectedEntry {
            HistoryDetailView(
                entry: entry,
                query: model.loadedQuery,
                playback: playback,
                modes: appState.modeManager?.modes ?? [],
                onCopy: copy,
                onDelete: {
                    playback.stopIfPlaying([entry.id])
                    model.delete(entry)
                },
                onReprocess: { mode in await reprocess(entry, with: mode) }
            )
            .id(entry.id)
        } else {
            emptyState(icon: "text.alignleft", title: "Select a recording", message: "Pick a recording to see its text, play it, or reprocess it.")
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        let clipboard = appState.services.output.clipboard
        clipboard.finish(clipboard.write(text, transient: false), restoreAfter: nil)
    }

    private func copySelection() {
        copy(HistoryGrouping.copyText(for: model.selectedEntries()))
        copiedSelection = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedSelection = false
        }
    }

    /// Runs the recording through `mode` again. The result goes only to the
    /// clipboard (reprocess runs never paste and are not saved).
    private func reprocess(_ entry: HistoryEntry, with mode: Mode) async -> String {
        guard let session = await appState.controller.reprocess(historyID: entry.id, mode: mode) else {
            return "Parrot is busy. Try again when the current dictation finishes."
        }
        switch session.outcome {
        case .copiedOnly, .pasted:
            return "Reprocessed with \(mode.name) and copied to the clipboard:\n\(session.text)"
        case .empty:
            return "Nothing came back from reprocessing this recording."
        case .failed(let message):
            return "Reprocessing failed: \(message)"
        default:
            return "Reprocessing did not finish."
        }
    }
}

// MARK: - Settings Panel

/// Save history, "Keep recordings for" with a delete-count confirmation,
/// and saving the prompt and context. [DATA]
struct HistorySettingsPanel: View {
    let onRetentionApplied: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var pendingDays: Int?
    @State private var pendingCount = 0

    var body: some View {
        @Bindable var history = appSettings.history
        Form {
            Toggle("Save history", isOn: $history.historyEnabled)
            Picker("Keep recordings for", selection: Binding(
                get: { history.historyRetentionDays },
                set: { request($0) }
            )) {
                ForEach(RetentionOption.choices(including: history.historyRetentionDays), id: \.self) { days in
                    Text(RetentionOption.label(forDays: days)).tag(days)
                }
            }
            Text("Older recordings are deleted automatically, audio included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Save prompt and context with each recording", isOn: $history.savePromptContext)
            Text("Stores the prompt sent to the language model and the captured context (such as selected text) in the recording's folder. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .alert("Delete Recordings", isPresented: Binding(get: { pendingDays != nil }, set: { if !$0 { pendingDays = nil } })) {
            Button("Delete", role: .destructive) {
                if let days = pendingDays { apply(days) }
                pendingDays = nil
            }
            Button("Cancel", role: .cancel) { pendingDays = nil }
        } message: {
            Text(RetentionOption.confirmationMessage(count: pendingCount))
        }
    }

    private func request(_ days: Int) {
        let current = appSettings.history.historyRetentionDays
        guard days != current else { return }
        if RetentionOption.needsConfirmation(from: current, to: days) {
            let count = (try? appState.historyStore?.countOlderThan(days: days)) ?? 0
            if count > 0 {
                pendingCount = count
                pendingDays = days
                return
            }
        }
        apply(days)
    }

    private func apply(_ days: Int) {
        appSettings.history.historyRetentionDays = days
        appState.services.recordings.applyRetention()
        onRetentionApplied()
    }
}

#Preview {
    HistoryView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 800, height: 500)
}
