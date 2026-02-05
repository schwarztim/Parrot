import SwiftUI

// MARK: - App Delegate

/// Manages window presentation at launch.
///
/// SwiftUI `Window` scenes inside a `MenuBarExtra`-only app are NOT presented
/// automatically. This delegate creates native `NSWindow`s hosting SwiftUI
/// views directly, which is the reliable pattern for menu bar apps.
final class ParrotAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var appState: AppState?
    var appSettings: AppSettings?
    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState, let appSettings else { return }

        // Sync persisted onboarding flag
        appState.hasCompletedOnboarding = appSettings.hasCompletedOnboarding

        DispatchQueue.main.async { [self] in
            if !appSettings.hasCompletedOnboarding {
                showOnboardingWindow()
            } else {
                showMainWindow()
            }
        }
    }

    func showOnboardingWindow() {
        guard let appState, let appSettings else { return }

        // Close main window if open
        mainWindow?.close()
        mainWindow = nil

        if onboardingWindow == nil {
            let view = OnboardingView(onComplete: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showMainWindow()
            })
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
        guard let appState, let appSettings else { return }

        // Close onboarding if open
        onboardingWindow?.close()
        onboardingWindow = nil

        if mainWindow == nil {
            let view = MainWindow()
                .environment(appState)
                .environment(appSettings)
                .onAppear {
                    appState.setup()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        appState.textEnhancer?.configure(from: appSettings)
                        appState.syncHotkeys(from: appSettings)
                    }
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

// MARK: - App

@main
struct ParrotApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: ParrotAppDelegate
    @State private var appState = AppState()
    @State private var appSettings = AppSettings()

    init() {
        // Wire delegate references before applicationDidFinishLaunching.
        // @NSApplicationDelegateAdaptor creates the delegate at init time.
        let state = AppState()
        let settings = AppSettings()
        _appState = State(initialValue: state)
        _appSettings = State(initialValue: settings)
        appDelegate.appState = state
        appDelegate.appSettings = settings
    }

    var body: some Scene {
        // MARK: - Menu Bar Extra

        MenuBarExtra {
            MenuBarContentView()
                .environment(appState)
                .environment(appSettings)
        } label: {
            Image(systemName: menuBarIconName)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var menuBarIconName: String {
        if appState.isRecording || appState.recordingState == .recording {
            return "mic.fill"
        }
        return "mic.fill"
    }
}

// MARK: - Menu Bar Content View

/// The dropdown content shown when clicking the menu bar icon.
private struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        // Status header
        statusSection

        Divider()

        // Open main window
        Button("Open Parrot...") {
            if let delegate = NSApplication.shared.delegate as? ParrotAppDelegate {
                delegate.showMainWindow()
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        // Quit
        Button("Quit Parrot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch appState.currentStatus {
        case .idle:
            Label("Ready", systemImage: "checkmark.circle")
        case .recording:
            Label("Recording...", systemImage: "mic.fill")
                .foregroundStyle(.red)
        case .processing:
            Label("Processing...", systemImage: "brain")
        case .error(let message):
            Label("Error: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .downloading(let progress):
            Label("Downloading model: \(Int(progress * 100))%", systemImage: "arrow.down.circle")
        }
    }
}
