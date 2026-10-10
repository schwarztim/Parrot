import AppKit
import SwiftUI

/// Creates and shows Parrot's windows. [UI]
///
/// SwiftUI `Window` scenes are not presented automatically in a menu bar
/// app, so these are native `NSWindow`s hosting SwiftUI views, which is the
/// reliable pattern for menu bar apps.
@MainActor
final class WindowManager {

    private let appState: AppState
    private let appSettings: AppSettings
    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?

    /// The recorder panel, following the live dictation state from launch.
    private(set) var recorder: RecorderWindowController?

    init(appState: AppState, appSettings: AppSettings) {
        self.appState = appState
        self.appSettings = appSettings
        recorder = RecorderWindowController.install(appState: appState, settings: appSettings) { [weak self] in
            self?.showTab(.sound)
        }
    }

    /// Opens the main window on `tab` (onboarding instead, if unfinished).
    func showTab(_ tab: SidebarTab) {
        guard appSettings.general.hasCompletedOnboarding else {
            showOnboardingWindow()
            return
        }
        showMainWindow()
        appState.navigation.request(tab)
    }

    /// Opens the main window, or resumes onboarding if it isn't finished.
    func openParrot() {
        if appSettings.general.hasCompletedOnboarding {
            showMainWindow()
        } else {
            showOnboardingWindow()
        }
    }

    func showOnboardingWindow() {
        // Close main window if open
        mainWindow?.close()
        mainWindow = nil

        if onboardingWindow == nil {
            let view = OnboardingView(onComplete: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showMainWindow()
            })
            .onAppear { NSApp.setActivationPolicy(.regular) }
            .environment(appState)
            .environment(appSettings)

            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Welcome to Parrot"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 600, height: 500))
            window.center()
            window.isReleasedWhenClosed = false
            self.onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showMainWindow() {
        // Close onboarding if open
        onboardingWindow?.close()
        onboardingWindow = nil

        // Once onboarding is done, become a menu-bar accessory (no Dock icon,
        // out of Cmd-Tab). The settings window still opens on demand.
        if appSettings.general.hasCompletedOnboarding {
            NSApp.setActivationPolicy(.accessory)
        }

        if mainWindow == nil {
            let appState = self.appState
            let view = MainWindow()
                .environment(appState)
                .environment(appSettings)
                .onAppear {
                    // setup() applies the saved hotkey binding before it
                    // starts listening, so no delayed sync is needed.
                    appState.setup()
                }

            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Parrot"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 800, height: 600))
            window.minSize = NSSize(width: 700, height: 500)
            window.center()
            window.isReleasedWhenClosed = false
            self.mainWindow = window
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
