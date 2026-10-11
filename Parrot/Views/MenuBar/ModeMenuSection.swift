import AppKit

/// The status menu's "Mode" submenu: every mode in the user's order, with a
/// checkmark on the active one. Choosing a mode makes it active. [LLM]
@MainActor
struct ModeMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] {
        let appState = context.appState
        let manager = appState.modeManager
        let modes = manager?.modes ?? appState.modes
        guard !modes.isEmpty else { return [] }
        let selectedID = manager?.selectedMode.id ?? appState.currentMode?.id

        let submenu = NSMenu(title: "Mode")
        for mode in modes {
            let item = ActionMenuItem(title: mode.name, systemImage: ModePresets.iconName(for: mode)) {
                if let manager {
                    manager.selectMode(mode)
                    appState.currentMode = manager.selectedMode
                } else {
                    appState.currentMode = mode
                }
            }
            item.state = mode.id == selectedID ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let windows = context.windows
        submenu.addItem(ActionMenuItem(title: "Edit Modes...", systemImage: "slider.horizontal.3") {
            windows.showTab(.modes)
        })

        let selectedName = modes.first { $0.id == selectedID }?.name
        let root = NSMenuItem(title: selectedName.map { "Mode: \($0)" } ?? "Mode", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        root.submenu = submenu
        return [root]
    }
}
