import SwiftUI

/// Audio processing rows before transcription: silence removal for now;
/// normalization and the short-clip gate later. [ASR]
///
/// SoundView embeds these rows in its Microphone section.
struct AudioProcessingSection: View {
    @Environment(AppSettings.self) private var appSettings

    init() {}

    var body: some View {
        @Bindable var transcription = appSettings.transcription

        Toggle("Silence Removal", isOn: $transcription.silenceRemoval)

        Text(
            "Removes silent segments from audio before processing. Reduces processing time and improves transcription accuracy."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
