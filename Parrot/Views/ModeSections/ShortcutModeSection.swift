import SwiftUI

/// Mode editor row for the shortcut that switches to this mode and starts
/// recording. [TRG]
///
/// Edits `mode.shortcut` on the editor's draft, so it saves with the mode.
/// HotkeyCenter registers every saved mode's shortcut.
struct ShortcutModeSection: View {
    @Binding var mode: Mode

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppState.self) private var appState: AppState?

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    var body: some View {
        Section("Keyboard Shortcut") {
            HotkeyRecorderView(
                label: "Start a recording in this mode",
                summary: "Switches to this mode and starts recording, without opening settings.",
                shortcut: Binding(
                    get: { mode.shortcut.map { Shortcut(mode: $0) } },
                    set: { mode.shortcut = $0?.modeShortcut }
                ),
                conflict: { candidate in
                    ShortcutRegistry.conflictName(
                        for: candidate,
                        assigningTo: .mode(mode.id),
                        hotkeys: appSettings.hotkeys,
                        modes: appState?.modeManager?.modes ?? appState?.modes ?? []
                    )
                }
            )
        }
    }
}
