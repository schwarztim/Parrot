import AppKit
import SwiftUI

// MARK: - Floating Panel (NSPanel Wrapper)

/// A borderless, non-activating floating panel on every Space, used by the
/// recorder and the error toast. It never takes focus from the active app.
class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Floating panel configuration
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        // Don't steal focus from active app
        becomesKeyOnlyIfNeeded = true
    }
}

// MARK: - Overlay Panel

/// The recorder presenter AppState calls (`showRecorder`, `hideRecorder`).
///
/// The window itself is `RecorderWindowController`, which WindowManager
/// installs at launch and which follows `LiveRecordingState` on its own;
/// these calls make sure it exists and is up to date.
@MainActor
enum RecordingOverlayPanel {

    static func show(appState: AppState) {
        if let controller = RecorderWindowController.current {
            controller.refresh()
        } else if let settings = appState.settings {
            RecorderWindowController.install(appState: appState, settings: settings)
        }
    }

    static func hide() {
        RecorderWindowController.current?.refresh()
    }
}
