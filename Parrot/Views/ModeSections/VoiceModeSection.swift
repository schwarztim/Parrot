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
    @State private var downloadProgress: Double?
    @State private var downloadError: String?

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

    var body: some View {
        Section("Voice") {
            Picker("Voice model", selection: modelID) {
                Text("Default (\(defaultModel.name))").tag("")
                ForEach(VoiceModels.all) { option in
                    Text(option.name).tag(option.id)
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
        HStack {
            Label("\(model.name) is selected but not downloaded.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            if let downloadProgress {
                ProgressView(value: downloadProgress)
                    .frame(width: 80)
            } else if appState != nil {
                Button("Download") { startDownload() }
            }
        }
        if let downloadError {
            Text(downloadError)
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

    private func startDownload() {
        guard let appState else { return }
        let target = model
        downloadError = nil
        downloadProgress = 0
        Task {
            do {
                try await appState.services.transcription.download(target, settings: appSettings) { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                downloadProgress = nil
                await refreshDownloaded()
            } catch {
                downloadProgress = nil
                downloadError = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
