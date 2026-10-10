import SwiftUI

/// Keyboard and mouse shortcuts for recording. [TRG]
///
/// One recorder per configurable `ShortcutName`, each saving through
/// `settings.hotkeys`. HotkeyCenter observes those settings, so a change
/// applies at once.
struct ShortcutsSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    private var modes: [Mode] { appState.modeManager?.modes ?? appState.modes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcuts")
                        .font(.title2.weight(.semibold))
                    Text("Customize your shortcuts: change the keyboard shortcuts for Parrot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    Section {
                        ForEach(ShortcutName.configurable) { name in
                            HotkeyRecorderView(
                                label: name.title,
                                summary: name.summary,
                                shortcut: binding(for: name),
                                defaultShortcut: name.defaultShortcut,
                                allowsKeys: name != .clickToTalk,
                                allowsMouse: [.pushToTalk, .toggleRecording, .clickToTalk].contains(name),
                                conflict: { candidate in
                                    ShortcutRegistry.conflictName(
                                        for: candidate,
                                        assigningTo: .name(name),
                                        hotkeys: appSettings.hotkeys,
                                        modes: modes
                                    )
                                }
                            )
                        }
                    } header: {
                        Text("Keyboard Shortcuts")
                    } footer: {
                        Text(holdHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Mode Specific Shortcuts") {
                        Text("Set keyboard shortcuts for each mode, so you can start recording directly in the mode you want. Edit a mode to set its shortcut.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(modes.filter { $0.shortcut != nil }, id: \.id) { mode in
                            if let shortcut = mode.shortcut {
                                HStack {
                                    Text(mode.name)
                                    Spacer()
                                    ShortcutKeycaps(shortcut: Shortcut(mode: shortcut))
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    private var holdHint: String {
        let hotkeys = appSettings.hotkeys
        let ptt = hotkeys.shortcut(for: .pushToTalk)
        if !ptt.isEmpty, ptt.overlaps(hotkeys.shortcut(for: .toggleRecording)) {
            return "Push to Talk and Toggle Recording share a key: tap it to start and tap again to stop, or hold it for at least 1 second and release to stop."
        }
        return "Tap Push to Talk to keep recording until the next press, or hold it for at least half a second and release to stop. Cancel works only while recording."
    }

    private func binding(for name: ShortcutName) -> Binding<Shortcut?> {
        let hotkeys = appSettings.hotkeys
        return Binding(
            get: {
                let shortcut = hotkeys.shortcut(for: name)
                return shortcut.isEmpty ? nil : shortcut
            },
            set: { hotkeys.setShortcut($0 ?? Shortcut.none, for: name) }
        )
    }
}

#Preview {
    ShortcutsSettingsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 560, height: 640)
}
