import SwiftUI

// MARK: - App Delegate

/// Starts the menu bar icon and the first window at launch, and routes
/// URLs. Window code lives in WindowManager, the menu bar icon and menu in
/// StatusItemController, URL handling in URLRouter.
@MainActor
final class ParrotAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var appState: AppState?
    var appSettings: AppSettings?
    private(set) var windows: WindowManager?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState, let appSettings else { return }

        let windows = WindowManager(appState: appState, appSettings: appSettings)
        self.windows = windows
        statusItem = StatusItemController(
            context: MenuContext(appState: appState, settings: appSettings, windows: windows)
        )

        DispatchQueue.main.async {
            if !appSettings.general.hasCompletedOnboarding {
                // Regular activation during onboarding so the wizard and the
                // system TCC prompts reliably take focus.
                NSApp.setActivationPolicy(.regular)
                windows.showOnboardingWindow()
            } else {
                windows.showMainWindow()
            }
        }
    }

    /// Re-check permissions whenever Parrot comes to the foreground, so grants
    /// or revocations made in System Settings (or lost on an app update) are
    /// reflected in the menu bar health surface.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            appState?.refreshPermissionHealth()
        }
    }

    /// Created on first use: a launch-by-URL can deliver URLs before
    /// `applicationDidFinishLaunching`.
    private var urlRouter: URLRouter?

    /// Hands `parrot://` and file URLs to URLRouter.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let appState else { return }
        let router = urlRouter ?? URLRouter(appState: appState)
        urlRouter = router
        router.handle(urls)
    }
}

// MARK: - App

@main
struct ParrotApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: ParrotAppDelegate
    @State private var appState: AppState
    @State private var appSettings: AppSettings

    init() {
        // Wire delegate references before applicationDidFinishLaunching.
        // @NSApplicationDelegateAdaptor creates the delegate at init time.
        let state = AppState()
        let settings = AppSettings()
        _appState = State(initialValue: state)
        _appSettings = State(initialValue: settings)
        state.settings = settings
        appDelegate.appState = state
        appDelegate.appSettings = settings
    }

    var body: some Scene {
        // The menu bar icon is an NSStatusItem and the windows are NSWindows
        // (see ParrotAppDelegate). SwiftUI still needs one scene: an empty
        // Settings scene keeps the app running without opening anything.
        Settings {
            EmptyView()
        }
        .commands {
            // Drop the app menu's Settings item, which would open the empty
            // scene.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}
