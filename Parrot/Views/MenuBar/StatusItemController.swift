import AppKit
import Observation

/// The menu bar icon and its menu. [UI]
///
/// Clicking the icon opens a menu that MenuLayout rebuilds each time it
/// opens. The icon flags missing permissions once onboarding is done.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let context: MenuContext
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(context: MenuContext) {
        self.context = context
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        observeIcon()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuLayout.populate(menu, context: context)
    }

    // MARK: - Icon

    /// Sets the icon and sets it again whenever a value it reads changes.
    private func observeIcon() {
        let name = withObservationTracking {
            iconName
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeIcon()
            }
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Parrot")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private var iconName: String {
        let appState = context.appState
        if appState.isRecording || appState.recordingState == .recording {
            return "mic.fill"
        }
        // Flag missing permissions right in the menu bar glyph, but only once
        // onboarding is done (during onboarding the wizard owns permissions).
        if context.settings.general.hasCompletedOnboarding, !appState.permissionWarnings.isEmpty {
            return "mic.badge.xmark"
        }
        return "mic.fill"
    }
}
