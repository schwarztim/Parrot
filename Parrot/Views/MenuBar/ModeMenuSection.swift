import AppKit

/// Active mode picker. [LLM]
///
/// Stub: no items yet.
@MainActor
struct ModeMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] { [] }
}
