import SwiftUI

struct SoundView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    /// The sound effects picker combines Off with the two themes.
    private enum EffectsChoice: Hashable {
        case off
        case theme(SoundTheme)
    }

    var body: some View {
        // Every control persists across launches.
        @Bindable var audio = appSettings.audio
        let devices = appState.services.devices

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sound")
                        .font(.title2.weight(.semibold))
                    Text("Microphone, playback while recording and sound effects")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                // Settings Form
                Form {
                    // Input Device
                    Section("Input Device") {
                        DevicePickerView(devices: devices)
                            .padding(.vertical, 2)

                        AudioLevelMeter(level: appState.inputLevel)
                            .padding(.vertical, 4)
                    }

                    // Microphone Settings
                    Section("Microphone") {
                        Toggle("Automatically increase microphone volume", isOn: $audio.autoMicVolume)

                        Text(
                            "Sets microphone input volume to max when starting a recording. Only works if using system default device."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        AudioProcessingSection()
                    }

                    // Playback
                    Section("Playback") {
                        Picker("Playback when recording", selection: $audio.playbackBehavior) {
                            ForEach(PlaybackBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.label).tag(behavior)
                            }
                        }

                        Text(
                            "Default playback behavior during recording. Individual modes can override this setting. Pause stops Music and Spotify and lowers other audio."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // Sound Effects
                    Section("Sound Effects") {
                        Picker("Sound effects", selection: effectsChoice(audio)) {
                            Text("Off").tag(EffectsChoice.off)
                            ForEach(SoundTheme.allCases, id: \.self) { theme in
                                Text(theme.label).tag(EffectsChoice.theme(theme))
                            }
                        }

                        HStack {
                            Text("Volume")

                            Slider(
                                value: $audio.soundEffectsVolume,
                                in: 0...1,
                                step: 0.05
                            )
                            .disabled(!audio.soundEffectsEnabled)

                            Text("\(Int(audio.soundEffectsVolume * 100))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .opacity(audio.soundEffectsEnabled ? 1.0 : 0.5)

                        HStack {
                            Button {
                                appState.services.sounds.preview(.start, settings: audio)
                            } label: {
                                Label("Start", systemImage: "play.circle")
                            }
                            .help("Click to play Start recording sound")

                            Button {
                                appState.services.sounds.preview(.stop, settings: audio)
                            } label: {
                                Label("Stop", systemImage: "play.circle")
                            }
                            .help("Click to play Stop recording sound")

                            Button {
                                appState.services.sounds.preview(.finish(.empty), settings: audio)
                            } label: {
                                Label("No Result", systemImage: "play.circle")
                            }
                            .help("Click to play the sound for a recording with no text")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            appState.startInputMonitoring()
        }
        .onDisappear {
            appState.stopInputMonitoring()
        }
        .onChange(of: devices.activeDevice) {
            // The meter follows the device recordings will use.
            appState.stopInputMonitoring()
            appState.startInputMonitoring()
        }
    }

    private func effectsChoice(_ audio: AudioSettings) -> Binding<EffectsChoice> {
        Binding(
            get: { audio.soundEffectsEnabled ? .theme(audio.soundTheme) : .off },
            set: { choice in
                switch choice {
                case .off:
                    audio.soundEffectsEnabled = false
                case .theme(let theme):
                    audio.soundEffectsEnabled = true
                    audio.soundTheme = theme
                }
            }
        )
    }
}

// MARK: - Audio Level Meter

/// Displays a horizontal bar showing the current microphone input level
/// with a green → yellow → red gradient.
struct AudioLevelMeter: View {
    let level: Float

    /// Number of segments in the meter.
    private let segmentCount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input Level")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(0..<segmentCount, id: \.self) { index in
                        let threshold = Float(index) / Float(segmentCount)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(segmentColor(for: index))
                            .opacity(level > threshold ? 1.0 : 0.15)
                    }
                }
            }
            .frame(height: 12)
            .animation(.linear(duration: 0.05), value: level)
        }
    }

    private func segmentColor(for index: Int) -> Color {
        let fraction = Double(index) / Double(segmentCount)
        if fraction < 0.6 {
            return .green
        } else if fraction < 0.8 {
            return .yellow
        } else {
            return .red
        }
    }
}

#Preview {
    SoundView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
