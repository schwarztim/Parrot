import AppKit

/// Dictation status and permission health rows. [UI]
@MainActor
struct RecordingMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] {
        var items = [statusItem()]

        // Permission health rows (only after onboarding, only when unhealthy).
        if context.settings.general.hasCompletedOnboarding {
            let warnings = context.appState.permissionWarnings
            if !warnings.isEmpty {
                items.append(.separator())
                let appState = context.appState
                for warning in warnings {
                    items.append(ActionMenuItem(title: warning.message, systemImage: "exclamationmark.triangle.fill") {
                        appState.openPermissionSettings(warning.pane)
                    })
                }
            }
        }
        return items
    }

    private func statusItem() -> NSMenuItem {
        let title: String
        let symbol: String
        switch context.appState.currentStatus {
        case .idle:
            title = "Ready"
            symbol = "checkmark.circle"
        case .recording:
            title = "Recording..."
            symbol = "mic.fill"
        case .processing:
            title = "Processing..."
            symbol = "brain"
        case .error(let message):
            title = "Error: \(message)"
            symbol = "exclamationmark.triangle"
        case .downloading(let progress):
            title = "Downloading model: \(Int(progress * 100))%"
            symbol = "arrow.down.circle"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = false
        return item
    }
}
