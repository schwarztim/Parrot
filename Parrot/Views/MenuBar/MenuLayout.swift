import AppKit

/// What every status menu section can reach.
@MainActor
struct MenuContext {
    let appState: AppState
    let settings: AppSettings
    let windows: WindowManager
}

/// One group of status menu items. Each section lives in its owner's file
/// and has `init(context: MenuContext)`.
@MainActor
protocol MenuSection {
    /// The section's items, built fresh each time the menu opens. Empty
    /// hides the section.
    func items() -> [NSMenuItem]
}

/// Builds the status menu. Frozen: the section order is fixed here.
@MainActor
enum MenuLayout {

    static func sections(context: MenuContext) -> [any MenuSection] {
        [
            RecordingMenuSection(context: context),
            FileMenuSection(context: context),
            WindowsMenuSection(context: context),
            MicrophoneMenuSection(context: context),
            ModeMenuSection(context: context),
        ]
    }

    /// Replaces `menu`'s items: every non-empty section with a separator
    /// between sections, then the version and Quit.
    static func populate(_ menu: NSMenu, context: MenuContext) {
        menu.removeAllItems()
        for section in sections(context: context) {
            let items = section.items()
            guard !items.isEmpty else { continue }
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(versionItem())
        menu.addItem(quitItem())
    }

    private static func versionItem() -> NSMenuItem {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let item = NSMenuItem(title: "Parrot \(version ?? "dev")", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func quitItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Quit Parrot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.target = NSApp
        return item
    }
}

/// A menu item that runs a closure when chosen.
final class ActionMenuItem: NSMenuItem {

    private let handler: @MainActor () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        keyEquivalent: String = "",
        handler: @escaping @MainActor () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("ActionMenuItem is created in code only")
    }

    /// AppKit sends menu actions on the main thread.
    @MainActor @objc private func fire() {
        handler()
    }
}
