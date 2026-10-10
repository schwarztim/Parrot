import SwiftUI

/// Mode editor rows for output: auto paste, autocapitalize and the mode's
/// AppleScript. [OUT]
///
/// ModeEditSheet embeds it in its Form and edits a draft mode, so every
/// field bound here survives Save.
struct OutputModeSection: View {
    @Binding var mode: Mode

    /// Optional so the section still renders where no settings are in the
    /// environment (the label then omits the global value).
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    init(mode: Binding<Mode>) {
        _mode = mode
    }

    /// The three choices behind the mode's optional `autoPaste`.
    private enum AutoPasteChoice: Hashable {
        case useDefault, on, off
    }

    private var autoPasteChoice: Binding<AutoPasteChoice> {
        Binding(
            get: {
                switch mode.autoPaste {
                case nil: return .useDefault
                case true?: return .on
                case false?: return .off
                }
            },
            set: { choice in
                switch choice {
                case .useDefault: mode.autoPaste = nil
                case .on: mode.autoPaste = true
                case .off: mode.autoPaste = false
                }
            }
        )
    }

    private var defaultLabel: String {
        guard let appSettings else { return "Default" }
        return "Default (\(appSettings.output.autoPaste ? "On" : "Off"))"
    }

    var body: some View {
        Section("Output") {
            Picker("Auto paste", selection: autoPasteChoice) {
                Text(defaultLabel).tag(AutoPasteChoice.useDefault)
                Text("On").tag(AutoPasteChoice.on)
                Text("Off").tag(AutoPasteChoice.off)
            }
            Text("Default follows the Text Input setting. On or Off applies to this mode only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Autocapitalize insert", isOn: $mode.autocapitalizeInsert)
            Text(
                "Matches the first word to where your cursor is: a capital at the start of a sentence, "
                    + "lowercase in the middle of one. Turn off to keep the text exactly as transcribed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("AppleScript") {
            Toggle("Run a script after each dictation", isOn: $mode.scriptEnabled)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $mode.script)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 80)
                if mode.script.isEmpty {
                    Text("Your AppleScript goes here")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }

            Text(
                "Write {{user_message}} where the dictated text should go, for example inside quotes: "
                    + "\"{{user_message}}\". The script runs after the text is delivered and stops after 10 seconds."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
