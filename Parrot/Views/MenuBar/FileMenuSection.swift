import AppKit

/// Transcribe a file. [ASR]
///
/// Stub: no items yet.
@MainActor
struct FileMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] { [] }
}
