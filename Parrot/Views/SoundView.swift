import SwiftUI

struct SoundView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var state = appState
        // The toggles, volume and microphone persist across launches.
        @Bindable var audio = appSettings.audio
        @Bindable var transcription = appSettings.transcription

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sound")
                        .font(.title2.weight(.semibold))
                    Text("Audio input and sound effect settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                // Settings Form
                Form {
                    // Input Device
                    Section("Input Device") {
                        Picker("Microphone", selection: $audio.selectedInputDeviceID) {
                            Text("System Default")
                                .tag(nil as String?)
                            ForEach(state.availableInputDevices) { device in
                                HStack {
                                    Text(device.name)
                                    if device.isDefault {
                                        Text("(Default)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(device.id as String?)
                            }
                        }

                        AudioLevelMeter(level: appState.inputLevel)
                            .padding(.vertical, 4)
                    }

                    // Microphone Settings
                    Section("Microphone") {
                        Toggle("Auto Mic Volume", isOn: $audio.autoMicVolume)

                        Text(
                            "Automatically adjusts microphone input volume for optimal recording quality. Recommended for most setups."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle("Silence Removal", isOn: $transcription.silenceRemoval)

                        Text(
                            "Removes silent segments from audio before processing. Reduces processing time and improves transcription accuracy."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // Sound Effects
                    Section("Sound Effects") {
                        Toggle("Enable Sound Effects", isOn: $audio.soundEffectsEnabled)

                        Text(
                            "Play audio cues when recording starts, stops, and when transcription completes."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
