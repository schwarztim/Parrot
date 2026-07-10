import AppKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    @State private var entries: [HistoryEntry] = []
    @State private var query: String = ""
    @State private var editingID: Int64?
    @State private var editText: String = ""
    @State private var showDeleteAll = false

    private let retentionOptions: [(String, Int)] = [
        ("7 days", 7), ("30 days", 30), ("90 days", 90), ("1 year", 365), ("Forever", 0),
    ]

    var body: some View {
        @Bindable var settings = appSettings

        VStack(spacing: 0) {
            header(settings: $settings)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: appState.lastTranscription) { _, _ in reload() }
        .task(id: query) {
            // Debounce search input.
            try? await Task.sleep(nanoseconds: 250_000_000)
            reload()
        }
    }

    // MARK: - Header

    private func header(settings: Bindable<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                        .font(.title2.weight(.semibold))
                    Text("Your recent dictations, searchable and on-device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(.controlBackgroundColor)))
                .frame(maxWidth: 260)

                Toggle("Save history", isOn: settings.historyEnabled)
                    .toggleStyle(.switch)

                Picker("Keep", selection: settings.historyRetentionDays) {
                    ForEach(retentionOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                .frame(maxWidth: 160)

                Spacer()

                Button(role: .destructive) {
                    showDeleteAll = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .padding(20)
        .confirmationDialog("Delete all history?", isPresented: $showDeleteAll) {
            Button("Delete All", role: .destructive) {
                try? appState.historyStore?.deleteAll()
                reload()
            }
        } message: {
            Text("This permanently removes every saved dictation.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !appSettings.historyEnabled {
            emptyState(
                icon: "nosign",
                title: "History is off",
                message: "Turn on Save history to keep a searchable record of your dictations."
            )
        } else if entries.isEmpty {
            emptyState(
                icon: query.isEmpty ? "clock" : "magnifyingglass",
                title: query.isEmpty ? "No dictations yet" : "No matches",
                message: query.isEmpty ? "Your dictations will appear here." : "Try a different search."
            )
        } else {
            List {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingID == entry.id {
                TextEditor(text: $editText)
                    .font(.body)
                    .frame(minHeight: 60)
                HStack {
                    Spacer()
                    Button("Cancel") { editingID = nil }
                    Button("Save") {
                        try? appState.historyStore?.updateFinalText(id: entry.id, newText: editText)
                        editingID = nil
                        reload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text(entry.finalText)
                    .font(.body)
                    .lineLimit(3)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(entry.timestamp, format: .relative(presentation: .named))
                    if let app = entry.appBundleID { Text(appName(app)) }
                    if let mode = entry.modeName { Text("· \(mode)") }
                    Spacer()
                    Button { copy(entry.finalText) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    Button { editingID = entry.id; editText = entry.finalText } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit")
                    Button(role: .destructive) {
                        try? appState.historyStore?.delete(id: entry.id)
                        reload()
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func reload() {
        entries = (try? appState.historyStore?.entries(matching: query)) ?? []
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleID
    }
}

#Preview {
    HistoryView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 600, height: 500)
}
