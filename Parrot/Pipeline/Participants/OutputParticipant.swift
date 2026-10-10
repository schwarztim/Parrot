import Foundation

/// Prefetches the paste target and caret context before delivery (OUT).
/// Stub: every hook is the default no-op.
@MainActor
final class OutputParticipant: RecordingParticipant {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }
}
