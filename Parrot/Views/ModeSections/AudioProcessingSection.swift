import SwiftUI

/// Audio processing rows before transcription: silence removal, dynamic
/// normalization and the short-clip gate. [ASR]
///
/// SoundView embeds these rows in its Microphone section.
struct AudioProcessingSection: View {
    @Environment(AppSettings.self) private var appSettings

    init() {}

    var body: some View {
        @Bindable var transcription = appSettings.transcription

        Toggle("Silence Removal", isOn: $transcription.silenceRemoval)
        Text(
            "Cuts silent stretches out of recordings before processing. Improves accuracy, avoids invented text, and speeds up long recordings with pauses."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Toggle("Dynamic Normalization", isOn: $transcription.dynamicNormalization)
        Text(
            "Evens out loudness before processing, which helps quiet or uneven microphones."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Toggle("Skip Silent Clips", isOn: $transcription.shortClipGate)
        Text(
            "Short recordings with no speech are discarded instead of transcribed, so an accidental press never pastes text."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
