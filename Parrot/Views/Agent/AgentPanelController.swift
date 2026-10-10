import AppKit
import SwiftUI

/// The floating agent panel. [AGT]
///
/// When an agent asks, the panel appears in the top-right corner without
/// taking keyboard focus, so typing elsewhere is never interrupted. It
/// takes focus only when the user invokes it (`show(activate: true)`) or
/// clicks into its editor. Closing it hands focus back to the app the user
/// was in, unless a recording is running.
@MainActor
final class AgentPanelController: AgentPanelPresenting {

    private let bridge: AgentBridge
    private weak var services: AppServices?
    private var window: AgentPanelWindow?
    private var previousApp: NSRunningApplication?
    private var resizeObserver: NSObjectProtocol?

    /// Panel width in points.
    static let width: CGFloat = 440
    private static let margin: CGFloat = 16

    init(bridge: AgentBridge, services: AppServices) {
        self.bridge = bridge
        self.services = services
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(activate: Bool) {
        let window = self.window ?? makeWindow()
        rememberFrontApp()
        if !window.isVisible {
            pinTopRight(window)
            window.orderFrontRegardless()
        }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hide(restoreFocus: Bool) {
        guard let window, window.isVisible else { return }
        let hadFocus = window.isKeyWindow || NSApp.isActive
        window.orderOut(nil)
        let recording = services.map { $0.live.phase != .idle } ?? false
        if restoreFocus, hadFocus, !recording, let app = previousApp, !app.isTerminated {
            app.activate()
        }
        previousApp = nil
    }

    // MARK: - Window

    private func makeWindow() -> AgentPanelWindow {
        let window = AgentPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240))
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AgentPanelView(bridge: bridge).frame(width: Self.width))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        // Keep the top-right corner in place as the content grows or shrinks.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.pinTopRight(window)
            }
        }
        self.window = window
        return window
    }

    private func pinTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - window.frame.width - Self.margin,
            y: visible.maxY - window.frame.height - Self.margin
        )
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    private func rememberFrontApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        previousApp = front
    }
}

/// A floating panel that can take keyboard focus for its editor while
/// staying non-activating (Parrot does not come to the front).
final class AgentPanelWindow: FloatingPanel {
    override var canBecomeKey: Bool { true }
}
