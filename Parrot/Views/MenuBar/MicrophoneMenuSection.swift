import AppKit

/// Microphone picker. [AUD]
///
/// Stub: no items yet.
@MainActor
struct MicrophoneMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] { [] }
}
