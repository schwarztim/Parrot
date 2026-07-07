import AppKit
import SwiftUI

/// Non-blocking floating error toast shown near the top of the screen.
///
/// Used when a cloud provider fails and the pipeline falls back to local
/// transcription or the raw transcript. Auto-dismisses after a few seconds
/// and never steals focus from the frontmost app.
@MainActor
enum ErrorToastPanel {

    private static var panel: FloatingPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ message: String, duration: TimeInterval = 4) {
        dismissTask?.cancel()
        panel?.close()

        let view = ErrorToastView(message: message)
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let newPanel = FloatingPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
        newPanel.contentView = hosting
        newPanel.isReleasedWhenClosed = false

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - hosting.fittingSize.width / 2,
                y: frame.maxY - hosting.fittingSize.height - 24
            )
            newPanel.setFrameOrigin(origin)
        }

        newPanel.orderFrontRegardless()
        panel = newPanel

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            panel?.close()
            panel = nil
        }
    }
}

// MARK: - Toast View

private struct ErrorToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .padding(8)
    }
}
