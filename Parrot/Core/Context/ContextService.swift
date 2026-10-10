import Foundation

/// Context sources for prompts: selection, clipboard, app, system. [LLM]
///
/// Stub: no behavior yet; ContextCaptureParticipant still uses
/// ContextSnapshotter. `start(services:)` runs once at the end of setup.
@MainActor
final class ContextService {
    init() {}

    func start(services: AppServices) {}
}
