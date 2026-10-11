import AppKit

/// History... and Settings..., which open Parrot's main window. [UI]
@MainActor
struct WindowsMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] {
        let windows = context.windows
        return [
            ActionMenuItem(title: "History...", systemImage: "clock.arrow.circlepath") {
                windows.showTab(.history)
            },
            // The main window (or onboarding if it isn't finished).
            ActionMenuItem(title: "Settings...", systemImage: "gearshape", keyEquivalent: ",") {
                windows.openParrot()
            },
        ]
    }
}
