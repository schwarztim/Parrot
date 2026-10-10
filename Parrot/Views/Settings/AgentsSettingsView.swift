import SwiftUI

/// Coding agent hooks: install, remove and options. [AGT]
///
/// Install edits the CLI's own settings file only when the user presses
/// the button; status is read live from those files each time the tab opens.
struct AgentsSettingsView: View {
    /// Shown in the sidebar (see SidebarTab.isAvailable).
    static let isReady = true

    @Environment(AppSettings.self) private var appSettings

    @State private var installer = AgentInstaller.live()
    @State private var statuses: [HookAgent: AgentHookStatus] = [:]
    @State private var messages: [HookAgent: String] = [:]

    var body: some View {
        @Bindable var agent = appSettings.agent

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents")
                        .font(.title2.weight(.semibold))
                    Text("Answer Claude Code and Codex by voice")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)

                Form {
                    Section {
                        Toggle("Show agent requests in Parrot", isOn: $agent.enabled)
                        Text("When an agent finishes, needs permission or asks a question, a panel shows its message. Dictate or type a reply and it goes back to the agent. Off, the agents ask in the terminal as usual.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Wait for an answer", selection: $agent.responseTimeout) {
                            Text("1 minute").tag(60.0)
                            Text("5 minutes").tag(300.0)
                            Text("10 minutes").tag(600.0)
                            Text("30 minutes").tag(1800.0)
                            Text("1 hour").tag(3600.0)
                        }
                        Text("After this the agent's own terminal prompt takes over.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Hooks") {
                        ForEach(HookAgent.allCases, id: \.self) { kind in
                            agentRow(kind)
                        }
                        if !installer.helperExists {
                            Label("This build has no parrot-agent-hook helper next to the app, so hooks cannot be installed.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Sessions") {
                        Text("Hide the panel with its close button; the agent keeps waiting until the timeout. \u{201C}Disable Parrot for this session\u{201D} keeps one session in the terminal. Type \u{201C}enable parrot\u{201D} there to turn it back on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 8)
            }
        }
        .onAppear(perform: refresh)
    }

    // MARK: - Rows

    private func agentRow(_ kind: HookAgent) -> some View {
        let status = statuses[kind] ?? AgentHookStatus()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: kind == .claude ? "sparkles" : "terminal")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.body.weight(.medium))
                    Text(status.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if status.installed {
                    if status.needsUpdate {
                        Button("Update") { run(kind, install: true) }
                    }
                    Button("Remove") { run(kind, install: false) }
                } else {
                    Button("Install") { run(kind, install: true) }
                        .disabled(!installer.helperExists)
                }
            }
            Toggle(isOn: Binding(
                get: { appSettings.agent.stopHookEnabled(for: kind) },
                set: { appSettings.agent.setStopHook($0, for: kind) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reply when the turn ends")
                    Text("\(kind.displayName) waits in the terminal while Parrot shows its message, up to the wait time above. Permissions and questions come to Parrot either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 28)
            if let message = messages[kind] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func refresh() {
        var result: [HookAgent: AgentHookStatus] = [:]
        for kind in HookAgent.allCases {
            result[kind] = AgentHookStatus(
                cli: installer.findCLI(kind),
                installed: installer.isInstalled(kind),
                needsUpdate: installer.needsUpdate(kind)
            )
        }
        statuses = result
    }

    private func run(_ kind: HookAgent, install: Bool) {
        do {
            let backup = install ? try installer.install(kind) : try installer.remove(kind)
            var text = install
                ? "Installed in \(installer.settingsFile(for: kind).path)."
                : "Removed from \(installer.settingsFile(for: kind).path)."
            if let backup { text += " Backup: \(backup.lastPathComponent)." }
            if install, kind == .codex {
                text += " Open Codex and run /hooks to trust Parrot's hooks; Codex skips new hooks until you do."
            }
            if install, !appSettings.agent.enabled {
                appSettings.agent.enabled = true
            }
            messages[kind] = text
        } catch {
            messages[kind] = error.localizedDescription
        }
        refresh()
    }
}

/// What the Agents tab shows for one CLI.
struct AgentHookStatus: Equatable {
    var cli: URL?
    var installed = false
    var needsUpdate = false

    var summary: String {
        let cliText = cli.map { "CLI found at \($0.path)" } ?? "CLI not found"
        let hookText = installed ? (needsUpdate ? "hooks point at another copy of Parrot" : "hooks installed") : "hooks not installed"
        return "\(cliText), \(hookText)"
    }
}
