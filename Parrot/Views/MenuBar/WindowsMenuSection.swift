import AppKit

/// Items that open Parrot's windows. [UI]
@MainActor
struct WindowsMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] {
        let windows = context.windows
        // Open main window (or resume onboarding if it isn't finished).
        return [
            ActionMenuItem(title: "Open Parrot...", keyEquivalent: ",") {
                windows.openParrot()
            },
        ]
    }
}
