import Foundation

/// Prefetches the paste target and caret context before delivery (OUT).
///
/// When the mic closes it starts reading the focused element in the
/// background, so FormatOutputStage and DeliverStage do not pay for the
/// Accessibility round trip. It also clears the last result text when a new
/// dictation starts.
@MainActor
final class OutputParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func willStart(_ session: DictationSession) async {
        services.live.resultText = nil
    }

    func willStop(_ session: DictationSession) {
        guard session.source == .live else { return }
        session.pasteTargetPrefetch = Task.detached(priority: .userInitiated) {
            CursorContextReader.read()
        }
    }
}

// MARK: - Session State

private enum PasteTargetPrefetchKey: SessionKey {
    static var defaultValue: Task<PasteTarget?, Never>? { nil }
}

private enum LeadingSpaceKey: SessionKey {
    static var defaultValue: Bool { false }
}

extension DictationSession {
    /// The focused element read when the mic closed; nil for file and
    /// reprocess runs.
    var pasteTargetPrefetch: Task<PasteTarget?, Never>? {
        get { self[PasteTargetPrefetchKey.self] }
        set { self[PasteTargetPrefetchKey.self] = newValue }
    }

    /// FormatOutputStage found the caret right after a word, so delivery
    /// puts a space in front. Kept apart from `text` so history and scripts
    /// get the clean text.
    var outputNeedsLeadingSpace: Bool {
        get { self[LeadingSpaceKey.self] }
        set { self[LeadingSpaceKey.self] = newValue }
    }
}
