import AppKit
import SwiftUI

/// The voice model library. [ASR]
///
/// Shown as the Voice segment of the Models tab: the default model and
/// cloud keys, then every model with capability chips, filters, favorites,
/// real download progress with cancel, and delete with the true size and
/// location on disk.
struct VoiceModelsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    @State private var filter = VoiceModelFilter()
    @State private var pendingDelete: VoiceModelInfo?
    @State private var deleteError: String?

    private var catalog: VoiceModelCatalog { appState.services.voiceCatalog }

    private var visibleModels: [VoiceModelInfo] {
        filter.apply(
            to: VoiceModels.all,
            favorites: appSettings.transcription.favorites,
            downloaded: catalog.downloadedIDs,
            showExperimental: appSettings.transcription.showExperimental
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Models")
                        .font(.title2.weight(.semibold))
                    Text("Voice recognition model library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                transcriptionProviderCard
                CloudKeysCard(credentials: appSettings.credentials)
                filterBar

                let models = visibleModels
                if models.isEmpty {
                    Text("No models match these filters.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(models) { model in
                        VoiceModelRow(
                            model: model,
                            catalog: catalog,
                            onDelete: { pendingDelete = model }
                        )
                    }
                }

                storageInfo
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .task { await catalog.refresh() }
        .confirmationDialog(
            "Are you sure you want to delete this model?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { model in
            Button("Delete \(model.name)", role: .destructive) { delete(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(deleteMessage(for: model))
        }
        .alert("Could not delete the model", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Default Model

    private var transcriptionProviderCard: some View {
        @Bindable var transcription = appSettings.transcription

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Default Model")
                    .font(.title3.weight(.semibold))

                Picker("Speech-to-Text", selection: $transcription.transcriptionProvider) {
                    ForEach(TranscriptionProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)

                switch transcription.transcriptionProvider {
                case .parakeet:
                    Text("Runs fully on-device. No network, no API key. Modes can pick any model below instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .openAI:
                    TextField("Model", text: $transcription.openAITranscriptionModel)
                        .textFieldStyle(.roundedBorder)
                    Text("whisper-1, gpt-4o-transcribe, or gpt-4o-mini-transcribe. Uses the OpenAI API key from Models > Language. Falls back to Parakeet on failure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .azureWhisper:
                    TextField("Whisper Deployment Name", text: $transcription.azureWhisperDeployment)
                        .textFieldStyle(.roundedBorder)
                    Text("Uses the Azure endpoint, API key, and API version from Models > Language. Falls back to Parakeet on failure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Picker("Keep model loaded", selection: $transcription.activeDuration) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1800.0)
                    Text("1 hour").tag(3600.0)
                    Text("Always").tag(0.0)
                }
                Text("How long an on-device voice model stays in memory after a dictation. It loads again when you next record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        @Bindable var transcription = appSettings.transcription

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Where", selection: $filter.location) {
                    ForEach(VoiceModelFilter.Location.allCases) { location in
                        Text(location.title).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Picker("Language", selection: $filter.language) {
                    Text("Any language").tag(String?.none)
                    ForEach(LanguageCatalog.whisper + LanguageCatalog.regional) { language in
                        Text(language.name).tag(String?.some(language.code))
                    }
                }
                .frame(maxWidth: 200)

                TextField("Search models", text: $filter.search)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                FilterChip(title: "Live text", systemImage: "text.bubble", isOn: $filter.liveText)
                FilterChip(title: "Speakers", systemImage: "person.2", isOn: $filter.speakers)
                FilterChip(title: "Favorites", systemImage: "star", isOn: $filter.favoritesOnly)
                FilterChip(title: "Downloaded", systemImage: "arrow.down.circle", isOn: $filter.downloadedOnly)
                Spacer()
                Toggle("Show experimental models", isOn: $transcription.showExperimental)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
        }
    }

    // MARK: - Storage

    private var storageInfo: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model Storage Locations")
                    .font(.caption.weight(.medium))
                ForEach(VoiceModelCatalog.storageRoots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(root.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Actions

    private func deleteMessage(for model: VoiceModelInfo) -> String {
        var lines = ["You won't be able to use it offline, but you can download it again anytime."]
        if let storage = catalog.storage[model.id] {
            lines.append("Frees \(ByteCountFormatter.string(fromByteCount: storage.bytes, countStyle: .file)) at \(storage.folder.path).")
        }
        return lines.joined(separator: "\n\n")
    }

    private func delete(_ model: VoiceModelInfo) {
        Task {
            do {
                try await catalog.delete(model)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

/// One model: name, favorite star, chips, ratings and its download state.
private struct VoiceModelRow: View {
    let model: VoiceModelInfo
    let catalog: VoiceModelCatalog
    let onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        catalog.toggleFavorite(model)
                    } label: {
                        Image(systemName: catalog.isFavorite(model) ? "star.fill" : "star")
                            .foregroundStyle(catalog.isFavorite(model) ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(catalog.isFavorite(model) ? "Remove from favorites" : "Add to favorites")

                    Text(model.name)
                        .font(.headline)
                    if model.isExperimental {
                        Text("Experimental")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    Spacer()
                    Text("Speed \(model.speed)/5 · Accuracy \(model.accuracy)/5")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(model.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ChipFlow(chips: Self.chips(for: model))

                if let requirement = model.requirement {
                    Label(requirement, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                stateRow
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch catalog.state(for: model) {
        case .cloud:
            HStack {
                if catalog.isConfigured(model) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(missingSetupText, systemImage: "key")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.callout)

        case .notDownloaded, .failed:
            HStack {
                if case .failed(let message) = catalog.state(for: model) {
                    Text("Download failed: \(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    catalog.download(model)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }

        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                let done = Int64(Double(model.downloadBytes) * fraction)
                Text("\(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { catalog.cancelDownload(model) }
            }

        case .downloaded:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let storage = catalog.storage[model.id] {
                    Text("\(ByteCountFormatter.string(fromByteCount: storage.bytes, countStyle: .file)) on disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([storage.folder])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(storage.folder.path)
                } else {
                    Text("Downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if catalog.canDelete(model) {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } else if model.id == VoiceModels.parakeetV3.id {
                    Text("Kept as the fallback model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var missingSetupText: String {
        if let preset = model.cloudPreset {
            return "Add your \(preset.vendor.displayName) API key above to use it."
        }
        return "Set up this provider in Models > Language."
    }

    /// The capability chips under a model.
    static func chips(for model: VoiceModelInfo) -> [Chip] {
        var chips: [Chip] = []
        chips.append(model.isOnDevice
            ? Chip(title: "On device", systemImage: "cpu", help: "Runs on this Mac. No internet needed.")
            : Chip(title: "Cloud", systemImage: "cloud", help: "Runs in the cloud. Requires an internet connection."))
        if model.supportsRealtime {
            chips.append(Chip(title: "Live text", systemImage: "text.bubble", help: "Streams results as you speak."))
        }
        if model.supportsDiarization {
            chips.append(Chip(title: "Speakers", systemImage: "person.2", help: "Identifies and labels different speakers."))
        }
        if model.supportsTranslation {
            chips.append(Chip(title: "Translates", systemImage: "globe", help: "Can translate audio to English."))
        }
        if model.supportsAutoLanguage {
            chips.append(Chip(title: "Detects language", systemImage: "character.bubble", help: "Detects the spoken language automatically."))
        }
        let languages = LanguageCatalog.languages(for: model)
        if languages.count == 1, let only = languages.first {
            chips.append(Chip(title: "\(only.name) only", systemImage: "textformat", help: "This model only supports \(only.name) audio."))
        } else {
            chips.append(Chip(title: "\(languages.count) languages", systemImage: "textformat", help: "Can output in multiple languages."))
        }
        if model.isOnDevice, model.downloadBytes > 0 {
            chips.append(Chip(
                title: ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file),
                systemImage: "internaldrive", help: "Download size."
            ))
        }
        return chips
    }
}

/// A small capability label.
private struct Chip: Hashable {
    let title: String
    let systemImage: String
    let help: String
}

/// Chips laid out in a wrapping row.
private struct ChipFlow: View {
    let chips: [Chip]

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                Label(chip.title, systemImage: chip.systemImage)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .help(chip.help)
            }
        }
    }
}

/// Places children left to right, wrapping to a new line when full.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A toggle drawn as a pill.
private struct FilterChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cloud Keys

/// API keys for the cloud voice vendors. Keys are saved through
/// ProviderCredentials and never shown again; only "saved" is displayed.
private struct CloudKeysCard: View {
    let credentials: ProviderCredentials

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cloud Voice Keys")
                    .font(.title3.weight(.semibold))
                Text("Bring your own keys: cloud models connect straight to each vendor with your key. OpenAI uses the key from Models > Language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach([CloudVoiceVendor.groq, .deepgram, .elevenLabs], id: \.self) { vendor in
                    KeyRow(vendor: vendor, credentials: credentials)
                }
            }
            .padding(4)
        }
    }
}

private struct KeyRow: View {
    let vendor: CloudVoiceVendor
    let credentials: ProviderCredentials
    @State private var draft = ""

    private var isSaved: Bool { !credentials.key(for: vendor.providerID).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Text(vendor.displayName)
                .frame(width: 90, alignment: .leading)
            SecureField(isSaved ? "Key saved. Paste a new one to replace it." : "API key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button("Save", action: save)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            if isSaved {
                Button("Remove") { credentials.removeKey(for: vendor.providerID) }
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        credentials.setKey(key, for: vendor.providerID)
        draft = ""
    }
}

#Preview {
    VoiceModelsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 700, height: 800)
}
