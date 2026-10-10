import SwiftUI

/// Keyboard shortcuts for dictation. [TRG]
struct ShortcutsSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var state = appState
        @Bindable var hotkeys = appSettings.hotkeys

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcuts")
                        .font(.title2.weight(.semibold))
                    Text("Keyboard shortcuts for recording")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    Section("Keyboard Shortcuts") {
                        HotkeyRecorderView(
                            label: "Toggle Recording",
                            requiredBinding: $hotkeys.hotkeyBinding
                        )

                        HotkeyRecorderView(
                            label: "Cancel Recording",
                            binding: $hotkeys.cancelHotkeyBinding
                        )

                        HotkeyRecorderView(
                            label: "Push to Talk (hold)",
                            binding: $hotkeys.pushToTalkBinding
                        )

                        HotkeyRecorderView(
                            label: "Enhance Recording",
                            binding: $state.enhanceRecordingHotkey
                        )

                        Text("Enhance: Records, transcribes, then polishes your text with AI before pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        // The bindings save themselves; sync the dictation one to the
        // runtime HotkeyManager.
        .onChange(of: appSettings.hotkeys.hotkeyBinding) { _, newValue in
            // Don't push broken keyCode:0 keyboard bindings
            if newValue.mouseButton != nil || newValue.keyCode != 0 {
                appState.hotkeyManager?.binding = AppState.toGlobalBinding(newValue)
            }
        }
    }
}

#Preview {
    ShortcutsSettingsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 600)
}
