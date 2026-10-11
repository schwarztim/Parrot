import SwiftUI

/// Play and pause plus a simple scrubber for one recording. [DATA]
struct AudioScrubber: View {
    let entry: HistoryEntry
    let playback: AudioPlaybackService

    @State private var scrubbing: Double?

    private var isCurrent: Bool { playback.currentID == entry.id }
    private var duration: Double {
        isCurrent && playback.duration > 0 ? playback.duration : max(entry.duration, 0.01)
    }
    private var position: Double { scrubbing ?? (isCurrent ? playback.currentTime : 0) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard let path = entry.audioPath else { return }
                playback.toggle(url: URL(fileURLWithPath: path), id: entry.id)
            } label: {
                Image(systemName: isCurrent && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(entry.audioPath == nil)
            .help(entry.audioPath == nil ? "No audio for this recording" : "Play")

            Slider(
                value: Binding(get: { position }, set: { scrubbing = $0 }),
                in: 0...duration
            ) { editing in
                if !editing, let target = scrubbing {
                    if !isCurrent, let path = entry.audioPath {
                        playback.play(url: URL(fileURLWithPath: path), id: entry.id)
                    }
                    playback.seek(to: target)
                    scrubbing = nil
                }
            }
            .disabled(entry.audioPath == nil)

            Text("\(HistoryGrouping.durationText(position)) / \(HistoryGrouping.durationText(duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottomLeading) {
            if isCurrent || playback.currentID == nil, let message = playback.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .offset(y: 16)
            }
        }
    }
}
