import SwiftUI

/// Text input settings: paste, clipboard, typing and auto-send. [OUT]
struct OutputSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var output = appSettings.output

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text(SidebarTab.textInput.label)
                        .font(.title2.weight(.semibold))
                    Text("How dictated text reaches the app you are typing in")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    Section("Paste") {
                        Toggle("Paste the result automatically", isOn: $output.autoPaste)
                        caption(
                            "When on, Parrot pastes the finished dictation into the field you are typing in. "
                                + "When off, the text waits on your clipboard. Each mode can override this."
                        )

                        if !appState.accessibilityPermissionGranted {
                            HStack {
                                Label("Pasting needs Accessibility access.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Open Settings") {
                                    appState.openPermissionSettings(.accessibility)
                                }
                            }
                        }
                    }

                    Section("Clipboard") {
                        Picker("After pasting", selection: $output.clipboardBehaviour) {
                            Text("Put back what I had copied (recommended)").tag(ClipboardBehaviour.keep)
                            Text("Keep the dictation on the clipboard").tag(ClipboardBehaviour.replace)
                        }
                        .pickerStyle(.radioGroup)
                        caption(
                            "Pasting goes through the clipboard. This chooses what it holds once the text is in."
                        )

                        Toggle("Let clipboard history apps keep dictations", isOn: $output.clipboardHistory)
                        caption(
                            "When off, dictations are marked so clipboard managers such as Maccy, Paste "
                                + "and Alfred skip them."
                        )
                    }

                    Section("Typing") {
                        Toggle("Type the text instead of pasting", isOn: $output.simulateKeypresses)
                        caption(
                            "Parrot presses the keys for you, so the text appears character by character. "
                                + "Experimental: built for the US QWERTY keyboard layout."
                        )
                    }

                    Section("Auto-send") {
                        Toggle("Hold Shift to send after pasting", isOn: $output.autoSubmitWithShift)
                        caption(
                            "When on, hold Shift as you finish a recording and Parrot presses Return after "
                                + "pasting, which sends the message in most chat apps."
                        )
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        // Show the real Accessibility status, which can change in System Settings.
        .onAppear {
            appState.refreshPermissionHealth()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    OutputSettingsView()
        .environment(AppState())
        .environment(AppSettings())
        .frame(width: 500, height: 700)
}
