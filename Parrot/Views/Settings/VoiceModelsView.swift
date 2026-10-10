import SwiftUI

/// The voice model library. [ASR]
///
/// Shown as the Voice segment of the Models tab.
struct VoiceModelsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Models")
                        .font(.title2.weight(.semibold))
                    Text("Voice recognition model library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                // Model Cards
                VStack(spacing: 16) {
                    transcriptionProviderCard

                    ForEach(appState.availableModels) { model in
                        modelCard(model)
                    }

                    // Storage Info
                    storageInfo
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Transcription Provider

    private var transcriptionProviderCard: some View {
        @Bindable var transcription = appSettings.transcription

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transcription Provider")
                    .font(.title3.weight(.semibold))

                Picker("Speech-to-Text", selection: $transcription.transcriptionProvider) {
                    ForEach(TranscriptionProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)

                switch transcription.transcriptionProvider {
                case .parakeet:
                    Text("Runs fully on-device. No network, no API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .openAI:
                    TextField("Model", text: $transcription.openAITranscriptionModel)
                        .textFieldStyle(.roundedBorder)
                    Text("whisper-1, gpt-4o-transcribe, or gpt-4o-mini-transcribe. Uses the OpenAI API key from Configuration > AI Refinement. Falls back to Parakeet on failure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .azureWhisper:
                    TextField("Whisper Deployment Name", text: $transcription.azureWhisperDeployment)
                        .textFieldStyle(.roundedBorder)
                    Text("Uses the Azure endpoint, API key, and API version from Configuration > AI Refinement. Falls back to Parakeet on failure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Model Card

    private func modelCard(_ model: VoiceModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // Title Row
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(model.name)
                                .font(.title3.weight(.semibold))

                            statusBadge(for: model)
                        }

                        Text("Neural speech recognition model")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Specs Grid
                HStack(spacing: 24) {
                    specItem(
                        icon: "internaldrive",
                        label: "Size",
                        value: model.sizeDescription
                    )
                    specItem(
                        icon: "globe",
                        label: "Languages",
                        value: "\(model.languageCount) supported"
                    )
                    specItem(
                        icon: "bolt",
                        label: "Performance",
                        value: model.performanceDescription
                    )
                }

                // Download / Status
                downloadSection(for: model)
            }
            .padding(4)
        }
    }

    private func statusBadge(for model: VoiceModel) -> some View {
        Group {
            if model.isDownloaded {
                Text("Ready")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green)
                    )
            } else if model.downloadProgress > 0 && model.downloadProgress < 1.0 {
                Text("Downloading")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange)
                    )
            } else {
                Text("Not Downloaded")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(.separatorColor), lineWidth: 1)
                    )
            }
        }
    }

    private func specItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func downloadSection(for model: VoiceModel) -> some View {
        if model.isDownloaded {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Model is ready to use")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if model.downloadProgress > 0 && model.downloadProgress < 1.0 {
            VStack(spacing: 8) {
                ProgressView(value: model.downloadProgress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(
                        "Downloading... \(Int(model.downloadProgress * 100))%"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    let downloadedMB = Int(
                        Double(model.sizeBytes) * model.downloadProgress / 1_000_000
                    )
                    let totalMB = Int(model.sizeBytes / 1_000_000)
                    Text("\(downloadedMB) / \(totalMB) MB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text("Download the model to enable voice recognition.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    downloadModel(model)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Storage Info

    private var storageInfo: some View {
        GroupBox {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Storage Location")
                        .font(.caption.weight(.medium))
                    Text(appState.modelStorageLocation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()
            }
            .padding(4)
        }
    }

    // MARK: - Actions

    private func downloadModel(_ model: VoiceModel) {
        // Placeholder: In production, this would trigger the actual download
        guard let index = appState.availableModels.firstIndex(where: { $0.id == model.id }) else {
            return
        }
        appState.availableModels[index].downloadProgress = 0.01
    }
}

#Preview {
    VoiceModelsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
