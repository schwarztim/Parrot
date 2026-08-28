import SwiftUI

struct VocabularyView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @State private var searchText = ""
    @State private var showingAddSheet = false

    private var filteredEntries: [VocabularyEntry] {
        if searchText.isEmpty {
            return appState.vocabularyEntries
        }
        let query = searchText.lowercased()
        return appState.vocabularyEntries.filter {
            $0.original.lowercased().contains(query)
                || $0.replacement.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Recognizer boosting toggle
            boostingBar

            Divider()

            // Search Bar
            searchBar

            Divider()

            // Content
            if appState.vocabularyEntries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noResultsState
            } else {
                vocabularyTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .sheet(isPresented: $showingAddSheet) {
            VocabularyEntrySheet(
                onSave: { entry in
                    appState.vocabularyEntries.append(entry)
                }
            )
        }
        .onChange(of: appState.vocabularyEntries) { _, _ in
            // Keep recognizer boosting in sync with vocabulary edits.
            if appSettings.vocabularyBoostingEnabled {
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
                Text("Custom word and phrase replacements")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingAddSheet = true
            } label: {
                Label("Add Entry", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(20)
    }

    // MARK: - Boosting Bar

    private var boostingBar: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Boost these terms in the recognizer", isOn: $settings.vocabularyBoostingEnabled)
                .onChange(of: settings.vocabularyBoostingEnabled) { _, _ in
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

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Filter vocabulary...", text: $searchText)
                .textFieldStyle(.plain)

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

    // MARK: - Table

    private var vocabularyTable: some View {
        List {
            // Table header
            HStack(spacing: 0) {
                Text("Original")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 30)

                Text("Replacement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Spacer for delete button
                Spacer()
                    .frame(width: 30)
            }
            .listRowSeparator(.hidden)

            ForEach(filteredEntries) { entry in
                vocabularyRow(entry)
            }
            .onDelete { indexSet in
                let idsToDelete = indexSet.map { filteredEntries[$0].id }
                appState.vocabularyEntries.removeAll { idsToDelete.contains($0.id) }
            }
        }
        .listStyle(.inset)
    }

    private func vocabularyRow(_ entry: VocabularyEntry) -> some View {
        HStack(spacing: 0) {
            Text(entry.original)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 30)

            Text(entry.replacement)
                .font(.body.weight(.medium))
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                appState.vocabularyEntries.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .frame(width: 30)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "text.book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No Vocabulary Entries")
                .font(.title3.weight(.medium))

            Text(
                "Add custom word replacements to improve transcription accuracy for specialized terms."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)

            Button("Add Entry") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)

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

// MARK: - Add Entry Sheet

struct VocabularyEntrySheet: View {
    let onSave: (VocabularyEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var original = ""
    @State private var replacement = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Vocabulary Entry")
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
                Section {
                    TextField("Original word or phrase", text: $original)
                    TextField("Replacement", text: $replacement)
                } header: {
                    Text("When the transcription contains the original word, it will be replaced.")
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

                Button("Add") {
                    let entry = VocabularyEntry(
                        original: original.trimmingCharacters(in: .whitespaces),
                        replacement: replacement.trimmingCharacters(in: .whitespaces)
                    )
                    onSave(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    original.trimmingCharacters(in: .whitespaces).isEmpty
                        || replacement.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
            .padding(20)
        }
        .frame(width: 400, height: 280)
    }
}

#Preview {
    VocabularyView()
        .environment(AppState())
        .frame(width: 500, height: 500)
}
