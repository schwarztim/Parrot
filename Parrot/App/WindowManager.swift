import AppKit
import Observation
import SwiftUI

/// Creates and shows Parrot's windows, and applies the theme and the Dock
/// icon policy. [UI]
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
    private var closeObservers: [NSObjectProtocol] = []

    /// The recorder panel, following the live dictation state from launch.
    private(set) var recorder: RecorderWindowController?

    init(appState: AppState, appSettings: AppSettings) {
        self.appState = appState
        self.appSettings = appSettings
        recorder = RecorderWindowController.install(
            appState: appState,
            settings: appSettings,
            openSoundSettings: { [weak self] in
                self?.showTab(.sound)
            },
            openTab: { [weak self] tab in
                if let tab {
                    self?.showTab(tab)
                } else {
                    self?.openParrot()
                }
            }
        )
        observeAppearance()
    }

    // MARK: - Theme and Dock

    /// The appearance for `theme`: nil follows the system.
    static func appearance(for theme: AppTheme) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Regular (Dock icon, Cmd-Tab) when "Show in Dock" is on or a Parrot
    /// window is open; otherwise a menu bar accessory.
    static func activationPolicy(showInDock: Bool, windowOpen: Bool) -> NSApplication.ActivationPolicy {
        showInDock || windowOpen ? .regular : .accessory
    }

    /// Applies the theme and Dock policy now and whenever either changes.
    private func observeAppearance() {
        let theme = withObservationTracking {
            _ = appSettings.general.showInDock
            return appSettings.general.theme
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeAppearance()
            }
        }
        // No NSApplication in headless tests.
        guard let app = NSApp as NSApplication? else { return }
        let appearance = Self.appearance(for: theme)
        if app.appearance?.name != appearance?.name {
            app.appearance = appearance
        }
        updateActivationPolicy()
    }

    /// Sets the Dock policy from the setting and the open windows.
    /// `closing` is a window about to close, counted as closed.
    private func updateActivationPolicy(closing: NSWindow? = nil) {
        guard let app = NSApp as NSApplication? else { return }
        let windowOpen = [mainWindow, onboardingWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible
        }
        let policy = Self.activationPolicy(showInDock: appSettings.general.showInDock, windowOpen: windowOpen)
        if app.activationPolicy() != policy {
            app.setActivationPolicy(policy)
        }
    }

    private func watchClose(of window: NSWindow) {
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                self?.updateActivationPolicy(closing: closing)
            }
        }
        closeObservers.append(token)
    }

    // MARK: - Windows

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
            watchClose(of: window)
            self.onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showMainWindow() {
        // Close onboarding if open
        onboardingWindow?.close()
        onboardingWindow = nil

        if mainWindow == nil {
            let appState = self.appState
            let view = VStack(spacing: 0) {
                SettingsTopBar()
                Divider()
                MainWindow()
            }
            // The top bar sits in the title bar strip, beside the traffic lights.
            .ignoresSafeArea(.container, edges: .top)
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
            watchClose(of: window)
            self.mainWindow = window
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        // With "Show in Dock" off the Dock icon shows only while a window is open.
        updateActivationPolicy()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings Top Bar

/// The settings window's top bar (ui 3.1): back through the tab history,
/// the tab's title and the microphone picker. [UI]
struct SettingsTopBar: View {
    @Environment(AppState.self) private var appState
    @State private var showsMicPicker = false

    var body: some View {
        let navigation = appState.navigation
        let devices = appState.services.devices
        HStack(spacing: 10) {
            Button {
                navigation.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!navigation.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")

            Text(navigation.selectedTab.label)
                .font(.headline)

            Spacer()

            Button {
                showsMicPicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "mic")
                    Text(devices.activeDevice?.name ?? "System default")
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Choose microphone")
            .popover(isPresented: $showsMicPicker, arrowEdge: .bottom) {
                DevicePickerView(devices: devices) {
                    showsMicPicker = false
                }
                .padding(12)
                .frame(width: 300)
            }
        }
        // Clears the traffic lights.
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 38)
    }
}
