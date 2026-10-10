import Foundation

/// Connects Parrot to coding agents through the hook helper and
/// `parrot://agent-*` URLs. [AGT]
///
/// Stub: no behavior yet. `start(services:)` runs once at the end of setup.
@MainActor
final class AgentBridge {
    init() {}

    func start(services: AppServices) {}

    /// Handles a `parrot://agent-*` URL forwarded by URLRouter. Ignored for now.
    func handle(url: URL) {}
}
