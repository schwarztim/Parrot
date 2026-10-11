import Foundation

/// Hallucination and empty-result filtering, then literal punctuation (ASR).
///
/// Drops segments that start after the recording ends, treats a
/// transcript that is wholly an invented stock phrase as empty, ends the
/// session with `.empty` when nothing is left, and converts spoken
/// punctuation when the mode asks. `rawTranscript` keeps what the
/// recognizer returned; only `text` changes.
@MainActor
final class TranscriptCleanupStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        var text = session.text

        let duration = session.duration
        if duration > 0, !session.segments.isEmpty {
            let (kept, dropped) = HallucinationFilter.dropSegmentsPastEnd(session.segments, duration: duration)
            if dropped > 0 {
                diagLog("[Parrot:Cleanup] Dropped \(dropped) hallucinated segment(s) starting after audio end")
                session.segments = kept
                text = kept.map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        }

        if HallucinationFilter.isHallucination(text, speechSeconds: session.speechSeconds) {
            diagLog("[Parrot:Cleanup] Transcript is a known hallucination, treating as empty")
            text = ""
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.text = ""
            return .finish(.empty)
        }

        if session.mode?.literalPunctuation == true {
            text = LiteralPunctuation.apply(text)
        }
        session.text = text
        return .continue
    }
}
