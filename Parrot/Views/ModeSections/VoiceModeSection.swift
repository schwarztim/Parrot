import SwiftUI

/// Mode editor rows for the voice model: model, language, translate,
/// literal punctuation, live text and speaker identification. [ASR]
///
/// ModeEditSheet embeds it in its Form and edits a draft mode, so every
/// field bound here survives Save.
struct VoiceModeSection: View {
    @Binding var mode: Mode

    /// Optional so the section still renders where no app state is in the
    /// environment (the download row is then hidden).
    @Environment(AppSettings.self) private var appSettings: AppSettings?
    @Environment(AppState.self) private var appState: AppState?

    @State private var isDownloaded = true

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    /// The global model a mode with no voice model of its own uses.
    private var defaultModel: VoiceModelInfo {
        VoiceModels.model(for: appSettings?.transcription.transcriptionProvider ?? .parakeet)
    }

    private var model: VoiceModelInfo {
        VoiceModels.model(id: mode.voiceModelID) ?? defaultModel
    }

    private var rules: VoiceModeRules { VoiceModeRules(model: model, mode: mode) }

    private var modelID: Binding<String> {
        Binding(
            get: { VoiceModels.model(id: mode.voiceModelID) == nil ? "" : mode.voiceModelID },
            set: { id in
                mode.voiceModelID = id
                let picked = VoiceModels.model(id: id) ?? defaultModel
                mode = VoiceModeRules.adjusted(mode, for: picked)
            }
        )
    }

    private var language: Binding<String> {
        Binding(
            get: {
                let choices = LanguageCatalog.choices(for: model)
                return choices.contains { $0.code == mode.language }
                    ? mode.language : LanguageCatalog.defaultCode(for: model)
            },
            set: { mode.language = $0 }
        )
    }

    /// Picker entries: experimental models only when shown (or already
    /// chosen), favorites first.
    private var pickerModels: [VoiceModelInfo] {
        VoiceModelFilter().apply(
            to: VoiceModels.all,
            favorites: appSettings?.transcription.favorites ?? [],
            downloaded: [],
            showExperimental: appSettings?.transcription.showExperimental ?? false,
            keep: mode.voiceModelID
        )
    }

    var body: some View {
        Section("Voice") {
            Picker("Voice model", selection: modelID) {
                Text("Default (\(defaultModel.name))").tag("")
                let options = pickerModels
                let favorites = appSettings?.transcription.favorites ?? []
                let starred = options.filter { favorites.contains($0.id) }
                if !starred.isEmpty {
                    Section("Favorites") {
                        ForEach(starred) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
                Section("On device") {
                    ForEach(options.filter { $0.isOnDevice && !favorites.contains($0.id) }) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                Section("Cloud") {
                    ForEach(options.filter { !$0.isOnDevice && !favorites.contains($0.id) }) { option in
                        Text(option.name).tag(option.id)
                    }
                }
            }
            Text("Converts your speech to text. \(model.detail)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isOnDevice, !isDownloaded {
                downloadRow
            }

            Picker("Language", selection: language) {
                ForEach(LanguageCatalog.choices(for: model)) { choice in
                    Text(choice.name).tag(choice.code)
                }
            }
            if !model.supportsAutoLanguage {
                Text("Language detection is not supported for this model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Translate to English", isOn: $mode.translateToEnglish)
                .disabled(!model.supportsTranslation)
            Text(
                model.supportsTranslation
                    ? "Writes English text whatever language you speak."
                    : "This model cannot translate."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Literal punctuation", isOn: $mode.literalPunctuation)
            Text("Say \"comma\", \"period\", \"question mark\" or \"new line\" to type the symbol.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Live text", isOn: $mode.realtimeOutput)
                .disabled(!mode.realtimeOutput && !rules.canEnableRealtime)
            Text(
                rules.realtimeBlockedReason
                    ?? "Shows words as you speak. The final text still comes from the whole recording."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Identify speakers", isOn: $mode.diarize)
                .disabled(!mode.diarize && !rules.canEnableDiarize)
            Text(
                rules.diarizeBlockedReason
                    ?? "Separates and labels each speaker (Speaker 1, Speaker 2) in the recording."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task(id: model.id) {
            await refreshDownloaded()
        }
    }

    // MARK: - Download

    @ViewBuilder
    private var downloadRow: some View {
        let state = appState?.services.voiceCatalog.state(for: model)
        HStack {
            Label("\(model.name) is selected but not downloaded.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            if case .downloading(let fraction) = state {
                ProgressView(value: fraction)
                    .frame(width: 80)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                Button("Cancel") { appState?.services.voiceCatalog.cancelDownload(model) }
            } else if case .downloaded = state {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if appState != nil {
                Button("Download") { appState?.services.voiceCatalog.download(model) }
            }
        }
        if case .failed(let message) = state {
            Text("Download failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func refreshDownloaded() async {
        guard let appState, model.isOnDevice else {
            isDownloaded = true
            return
        }
        isDownloaded = await appState.services.transcription.isDownloaded(model, settings: appSettings)
    }
}
