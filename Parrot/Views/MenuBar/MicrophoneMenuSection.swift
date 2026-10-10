import AppKit

/// Microphone picker: a "Microphone" submenu with System Default and each
/// connected, non-hidden input device, a check on the current choice. [AUD]
@MainActor
struct MicrophoneMenuSection: MenuSection {
    let context: MenuContext

    init(context: MenuContext) {
        self.context = context
    }

    func items() -> [NSMenuItem] {
        let devices = context.appState.services.devices
        let submenu = NSMenu(title: "Microphone")

        let defaultTitle = devices.systemDefaultDevice.map { "System Default (\($0.name))" } ?? "System Default"
        let defaultItem = ActionMenuItem(title: defaultTitle) { devices.useSystemDefault() }
        defaultItem.state = devices.followsSystemDefault ? .on : .off
        submenu.addItem(defaultItem)

        let choices = devices.selectableDevices
        if !choices.isEmpty {
            submenu.addItem(.separator())
        }
        for device in choices {
            let item = ActionMenuItem(title: device.name) { devices.select(device) }
            item.state = devices.pinnedUID == device.uid ? .on : .off
            submenu.addItem(item)
        }

        let root = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        root.submenu = submenu
        return [root]
    }
}
