import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Words and replacements in one screen: one input adds a word, a sheet adds
/// a replacement, both edit inline, and a CSV can be imported. [DATA]
struct VocabularyView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var searchText = ""
    @State private var newText = ""
    @State private var showingReplacementSheet = false
    @State private var showingImportSheet = false

    private var entries: [VocabularyEntry] { appState.vocabularyEntries }

    private func matches(_ entry: VocabularyEntry) -> Bool {
        guard !searchText.isEmpty else { return true }
        let query = searchText.lowercased()
        return entry.original.lowercased().contains(query) || entry.replacement.lowercased().contains(query)
    }

    private var words: [VocabularyEntry] { entries.filter { $0.isWord && matches($0) } }
    private var replacements: [VocabularyEntry] { entries.filter { !$0.isWord && matches($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            FirstRunToastStack(
                screen: .vocabulary,
                satisfied: FirstRunToasts.satisfied(vocabulary: entries),
                padding: EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20)
            )
            Divider()
            boostingBar
            Divider()
            addBar
            Divider()
            if entries.isEmpty {
                emptyState
            } else if words.isEmpty && replacements.isEmpty {
                noResultsState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .sheet(isPresented: $showingReplacementSheet) {
            VocabularyEntrySheet { entry in
                appState.vocabularyManager.merge([entry])
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            VocabularyImportSheet { imported in
                appState.vocabularyManager.merge(imported)
            }
        }
        .onChange(of: appState.vocabularyEntries) { _, _ in
            // Keep recognizer boosting in sync with vocabulary edits.
            if appSettings.vocabulary.vocabularyBoostingEnabled {
                appState.refreshVocabularyBoosting()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vocabulary")
                    .font(.title2.weight(.semibold))
                Text("Words help recognition. Replacements swap text before it is pasted.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingImportSheet = true
            } label: {
                Label("Import CSV", systemImage: "square.and.arrow.down")
            }

            Button {
                showingReplacementSheet = true
            } label: {
                Label("Add Replacement", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    // MARK: - Boosting Bar

    private var boostingBar: some View {
        @Bindable var vocabularySettings = appSettings.vocabulary
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Boost these terms in the recognizer", isOn: $vocabularySettings.vocabularyBoostingEnabled)
                .onChange(of: vocabularySettings.vocabularyBoostingEnabled) { _, _ in
                    appState.refreshVocabularyBoosting()
                }
            Text("Biases on-device recognition toward your terms so they are transcribed correctly, not just replaced afterward. Downloads an additional recognizer model (~110M parameters) the first time you enable it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Add and Filter

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("New word or replacement", text: $newText)
                .textFieldStyle(.plain)
                .onSubmit(addWord)
            Button("Add", action: addWord)
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)

            Divider().frame(height: 18)

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .frame(maxWidth: 160)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor))
    }

    /// "word" adds a word; "spoken -> written" or "spoken => written" adds a
    /// replacement in one go.
    private func addWord() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        for arrow in ["=>", "->", "→"] {
            let parts = text.components(separatedBy: arrow)
            if parts.count == 2 {
                let original = parts[0].trimmingCharacters(in: .whitespaces)
                let replacement = parts[1].trimmingCharacters(in: .whitespaces)
                if !original.isEmpty, !replacement.isEmpty {
                    appState.vocabularyManager.merge([VocabularyEntry(original: original, replacement: replacement)])
                    newText = ""
                    return
                }
            }
        }
        appState.vocabularyManager.merge([.word(text)])
        newText = ""
    }

    // MARK: - List

    private var list: some View {
        List {
            if !words.isEmpty {
                Section("Words (\(words.count))") {
                    ForEach(words) { entry in
                        VocabularyRow(entry: entry, onCommit: update, onDelete: delete)
                    }
                }
            }
            if !replacements.isEmpty {
                Section("Replacements (\(replacements.count))") {
                    ForEach(replacements) { entry in
                        VocabularyRow(entry: entry, onCommit: update, onDelete: delete)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func update(_ entry: VocabularyEntry) {
        appState.vocabularyManager.updateEntry(entry)
    }

    private func delete(_ entry: VocabularyEntry) {
        appState.vocabularyManager.removeEntry(id: entry.id)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Vocabulary Yet")
                .font(.title3.weight(.medium))
            Text("Add names, company names, acronyms and jargon above. Use a replacement to turn a spoken phrase into other text, such as a link or a snippet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack {
                Button("Add Replacement") { showingReplacementSheet = true }
                Button("Import CSV") { showingImportSheet = true }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No results for \"\(searchText)\"")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

/// One word or replacement, edited in place. Edits are saved on Return or
/// when the field loses focus; delete shows on hover.
private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let onCommit: (VocabularyEntry) -> Void
    let onDelete: (VocabularyEntry) -> Void

    @State private var original = ""
    @State private var replacement = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { enabled in
                    var updated = entry
                    updated.isEnabled = enabled
                    onCommit(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(entry.isEnabled ? "Enabled" : "Disabled")

            TextField(entry.isWord ? "Word" : "Original word or phrase", text: $original)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(commit)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !entry.isWord {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Replacement text", text: $replacement)
                    .textFieldStyle(.plain)
                    .foregroundColor(.accentColor)
                    .focused($focused)
                    .onSubmit(commit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                onDelete(entry)
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help("Delete")
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .onAppear(perform: load)
        .onChange(of: entry) { _, _ in load() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func load() {
        original = entry.original
        replacement = entry.isWord ? "" : entry.replacement
    }

    private func commit() {
        let newOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newOriginal.isEmpty else {
            load()
            return
        }
        var updated = entry
        updated.original = newOriginal
        if entry.isWord {
            updated.replacement = newOriginal
        } else {
            let newReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.replacement = newReplacement.isEmpty ? newOriginal : newReplacement
        }
        if updated != entry { onCommit(updated) }
    }
}

// MARK: - Add Replacement Sheet

struct VocabularyEntrySheet: View {
    let onSave: (VocabularyEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var original = ""
    @State private var replacement = ""

    private var trimmedOriginal: String { original.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedReplacement: String { replacement.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Replacement")
                    .font(.headline)
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    TextField("Original word or phrase", text: $original)
                    TextField("Replacement text", text: $replacement, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("When a dictation contains the original, it is replaced. The replacement can be a spelling, a link or a longer snippet.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave(VocabularyEntry(original: trimmedOriginal, replacement: trimmedReplacement))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedOriginal.isEmpty || trimmedReplacement.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440, height: 340)
    }
}

// MARK: - CSV Import Sheet

/// Drop or choose a `.csv`; "Save Example CSV" writes a sample file.
struct VocabularyImportSheet: View {
    let onImport: ([VocabularyEntry]) -> VocabularyMerge.Result

    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var isError = false
    @State private var targeted = false
    @State private var choosing = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Import Vocabulary")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Drop a CSV file here")
                    .font(.callout)
                Button("Choose File...") { choosing = true }
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
            )
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
                return true
            } isTargeted: { targeted = $0 }

            Text("The first row must name the columns: word, and optionally replacement. A row with no replacement adds a word.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Save Example CSV", action: saveExample)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): importFiles([url])
            case .failure: show(VocabularyCSV.ImportError.unreadable)
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        do {
            let url = try VocabularyCSV.validate(urls)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let entries = try VocabularyCSV.entries(fromFile: url)
            let result = onImport(entries)
            isError = false
            message = Self.summary(result)
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        isError = true
        message = error.localizedDescription
    }

    static func summary(_ result: VocabularyMerge.Result) -> String {
        var parts = ["Imported \(result.wordsAdded) words and \(result.replacementsAdded + result.upgraded) replacements."]
        if result.duplicates > 0 { parts.append("\(result.duplicates) were already in your vocabulary.") }
        return parts.joined(separator: " ")
    }

    private func saveExample() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = VocabularyCSV.exampleFileName
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(VocabularyCSV.exampleCSV.utf8).write(to: url, options: .atomic)
        } catch {
            isError = true
            message = "Could not save the example file."
        }
    }
}

#Preview {
    VocabularyView()
        .environment(AppState())
        .frame(width: 500, height: 500)
}
