import FluidAudio
import Foundation

/// One stretch of audio and who spoke it, in recording seconds.
struct SpeakerTurn: Equatable, Sendable {
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Finds who spoke when in a recording. [ASR]
protocol SpeakerDiarizer: AnyObject, Sendable {
    func isDownloaded() async -> Bool
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    func diarize(_ samples: [Float]) async throws -> [SpeakerTurn]
}

/// Speaker separation for dictations whose mode has "Identify speakers"
/// on. [ASR]
///
/// Cloud vendors that label words (Deepgram, ElevenLabs) already put a
/// speaker on each segment; those labels are renumbered. Every other
/// model's segments get speakers from the on-device FluidAudio diarizer,
/// by the largest overlap in time. Labels read "Speaker 1", "Speaker 2"
/// in order of first appearance. A diarizer failure never loses the
/// transcript: the segments stay unlabelled and a warning is recorded.
@MainActor
final class DiarizationService {

    let diarizer: any SpeakerDiarizer

    init(diarizer: any SpeakerDiarizer = FluidSpeakerDiarizer()) {
        self.diarizer = diarizer
    }

    /// The labelled segments, the speaker names in order, and a warning
    /// when the diarizer could not run.
    struct Outcome: Equatable {
        var segments: [TranscriptSegment]
        var speakers: [String]
        var warning: String?
    }

    func assignSpeakers(segments: [TranscriptSegment], recording: [Float]) async -> Outcome {
        if segments.contains(where: { $0.speaker != nil }) {
            let labelled = Self.renumber(segments)
            return Outcome(segments: labelled, speakers: Self.speakers(in: labelled))
        }
        guard !segments.isEmpty else { return Outcome(segments: segments, speakers: []) }
        do {
            if !(await diarizer.isDownloaded()) {
                // Speaker separation was asked for, so its small model is
                // fetched on first use.
                try await diarizer.download { _ in }
            }
            let turns = try await diarizer.diarize(recording)
            let labelled = Self.renumber(Self.assign(turns: turns, to: segments))
            return Outcome(segments: labelled, speakers: Self.speakers(in: labelled))
        } catch {
            diagLog("[Parrot:Diarize] Speaker separation failed: \(error.localizedDescription)")
            return Outcome(segments: segments, speakers: [], warning: "Speaker separation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure Steps

    /// Gives each segment the speaker whose turns overlap it most. A
    /// segment no turn touches takes the nearest turn's speaker.
    nonisolated static func assign(turns: [SpeakerTurn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { segment in
            var overlap: [String: TimeInterval] = [:]
            for turn in turns {
                let shared = min(segment.end, turn.end) - max(segment.start, turn.start)
                if shared > 0 { overlap[turn.speaker, default: 0] += shared }
            }
            var labelled = segment
            if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
                labelled.speaker = best.key
            } else {
                let middle = (segment.start + segment.end) / 2
                labelled.speaker = turns.min {
                    distance(middle, $0) < distance(middle, $1)
                }?.speaker
            }
            return labelled
        }
    }

    private nonisolated static func distance(_ time: TimeInterval, _ turn: SpeakerTurn) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    /// Renames raw speaker ids to "Speaker 1", "Speaker 2", ... in order
    /// of first appearance.
    nonisolated static func renumber(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var names: [String: String] = [:]
        return segments.map { segment in
            guard let raw = segment.speaker else { return segment }
            var labelled = segment
            if let name = names[raw] {
                labelled.speaker = name
            } else {
                let name = "Speaker \(names.count + 1)"
                names[raw] = name
                labelled.speaker = name
            }
            return labelled
        }
    }

    /// Speaker names in order of first appearance.
    nonisolated static func speakers(in segments: [TranscriptSegment]) -> [String] {
        var seen: [String] = []
        for case let speaker? in segments.map(\.speaker) where !seen.contains(speaker) {
            seen.append(speaker)
        }
        return seen
    }

    /// The transcript with a "Speaker N:" line before each change of
    /// speaker. Used when more than one speaker was found.
    nonisolated static func labelledText(_ segments: [TranscriptSegment]) -> String {
        var blocks: [String] = []
        var currentSpeaker: String?
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            let body = current.joined(separator: " ")
            blocks.append(currentSpeaker.map { "\($0): \(body)" } ?? body)
            current.removeAll()
        }
        for segment in segments {
            if segment.speaker != currentSpeaker { flush() }
            currentSpeaker = segment.speaker
            current.append(segment.text)
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }
}

// MARK: - FluidAudio Diarizer

/// FluidAudio's pyannote segmentation plus WeSpeaker embedding diarizer
/// (about 14 MB). Models load on first use and stay loaded. [ASR]
actor FluidSpeakerDiarizer: SpeakerDiarizer {
    private var manager: DiarizerManager?

    /// Where FluidAudio keeps the diarizer models.
    static var cacheDirectory: URL {
        DiarizerModels.defaultModelsDirectory()
    }

    func isDownloaded() -> Bool {
        ModelFiles.complete(at: Self.cacheDirectory, required: Array(DiarizerModels.requiredModelNames))
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let models = try await DiarizerModels.downloadIfNeeded { update in progress(update.fractionCompleted) }
        let made = DiarizerManager()
        made.initialize(models: models)
        manager = made
    }

    func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        if manager == nil {
            let models = try await DiarizerModels.load()
            let made = DiarizerManager()
            made.initialize(models: models)
            manager = made
        }
        guard let manager else { return [] }
        let result = try manager.performCompleteDiarization(samples, sampleRate: Int(AudioFrame.sampleRate))
        return result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    func unload() {
        manager?.cleanup()
        manager = nil
    }
}
