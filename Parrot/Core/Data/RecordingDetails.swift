import Foundation

/// The full metadata of one recording, loaded lazily from its folder when
/// it is selected (list rows come from the index only). [DATA]
struct RecordingDetails: Equatable {
    var segments: [TranscriptSegment] = []
    var speakers: [String] = []
    /// Parrot recordings saved with `savePromptContext` on; never imported.
    var renderedPrompt: String?
    var device: String?
    var appVersion: String?
    var flags: RecordingMeta.Flags?
    var timings: [String: Double] = [:]

    /// Reads Parrot's `meta.json`, or an imported Superwhisper one
    /// (read-only, without its prompt or context). Nil when the folder or
    /// file is missing or unreadable; the caller keeps the index row.
    static func load(for entry: HistoryEntry) -> RecordingDetails? {
        guard let path = entry.folderPath else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let url = folder.appendingPathComponent(RecordingMeta.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }

        if entry.isImported {
            guard let meta = try? JSONDecoder().decode(Superwhisper.Meta.self, from: data) else {
                diagLog("[Parrot:History] Error loading full metadata from meta.json")
                return nil
            }
            return RecordingDetails(
                segments: meta.transcriptSegments,
                speakers: meta.speakerNames,
                renderedPrompt: nil,
                device: meta.recordingDevice,
                appVersion: meta.appVersion,
                flags: RecordingMeta.Flags(
                    translate: meta.translationEnabled ?? false,
                    literalPunctuation: meta.literalPunctuationEnabled ?? false,
                    realtime: meta.realtimeEnabled ?? false,
                    diarize: meta.separateSpeakersEnabled ?? false,
                    systemAudio: meta.systemAudioEnabled ?? false,
                    applicationContext: meta.applicationContextEnabled ?? false
                )
            )
        }

        guard let meta = try? JSONDecoder().decode(RecordingMeta.self, from: data) else {
            diagLog("[Parrot:History] Error loading full metadata from meta.json")
            return nil
        }
        return RecordingDetails(
            segments: meta.segments,
            speakers: meta.speakers,
            renderedPrompt: meta.renderedPrompt,
            device: meta.device,
            appVersion: meta.appVersion,
            flags: meta.flags,
            timings: meta.timings
        )
    }

    /// Consecutive segments from the same speaker merged for the Speakers
    /// view.
    static func speakerTurns(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var turns: [TranscriptSegment] = []
        for segment in segments {
            if var last = turns.last, last.speaker == segment.speaker {
                last.text = [last.text, segment.text].filter { !$0.isEmpty }.joined(separator: " ")
                last.end = segment.end
                turns[turns.count - 1] = last
            } else {
                turns.append(segment)
            }
        }
        return turns
    }
}
