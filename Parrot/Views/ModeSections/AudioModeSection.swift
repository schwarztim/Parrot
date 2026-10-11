import SwiftUI

/// Mode editor rows for audio: playback while recording, system audio.
/// [AUD]
///
/// ModeEditSheet embeds it in its Form and edits a draft mode, so every
/// field bound here survives Save.
struct AudioModeSection: View {
    @Binding var mode: Mode

    /// Optional so the section still renders where no settings are in the
    /// environment (the default label then shows the built-in default).
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    /// The "use default" row names the current global value.
    static func defaultLabel(global: PlaybackBehavior) -> String {
        "\(global.label) (Default)"
    }

    var body: some View {
        Section("Audio") {
            Picker("Playback when recording", selection: $mode.playbackBehavior) {
                Text(Self.defaultLabel(global: appSettings?.audio.playbackBehavior ?? .pause))
                    .tag(nil as PlaybackBehavior?)
                ForEach(PlaybackBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.label).tag(behavior as PlaybackBehavior?)
                }
            }
            Text("Pause, lower, or mute your music and video while recording. Playback settings are restored once recording is complete.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Record from system audio", isOn: $mode.useSystemAudio)
            Text("If enabled, audio will be recorded from applications on your main display along with your microphone. Needs Screen Recording permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
