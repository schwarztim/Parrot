import SwiftUI

/// The agent panel's content: header, the agent's last message, and the
/// answer area for the request kind. [AGT]
struct AgentPanelView: View {
    @Bindable var bridge: AgentBridge
    @State private var confirmingDisable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = bridge.currentSession {
                AgentPanelHeader(session: session, queued: bridge.waitingCount - 1) {
                    bridge.hidePanel()
                }
                AgentSummaryBubble(session: session)
                switch session.event {
                case .stop:
                    replyArea(session)
                case .permission:
                    AgentPermissionView(bridge: bridge, session: session)
                case .question:
                    if bridge.elicitation != nil {
                        AgentElicitationView(bridge: bridge)
                    } else {
                        // No question data (a link request): answer there.
                        HStack {
                            Spacer()
                            Button("Answer in Terminal") { Task { await bridge.dismissCurrent() } }
                        }
                    }
                case .plan:
                    planArea(session)
                }
                footer(session)
            } else if !bridge.activeBypasses.isEmpty {
                // No request waiting, but a bypass is on: keep its badge in view.
                AgentBypassBadges(bridge: bridge)
            } else {
                Text("No agent is waiting.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .padding(8)
        .onChange(of: bridge.currentSession?.requestId) { confirmingDisable = false }
    }

    // MARK: - Answer Areas

    private func replyArea(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentDraftEditor(text: $bridge.draft, placeholder: "Dictate or type your reply")
            HStack {
                Text("Speak with your dictation shortcut, or type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Let It Stop") { Task { await bridge.dismissCurrent() } }
                Button("Send") { Task { await bridge.sendDraft() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(bridge.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func planArea(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentDraftEditor(text: $bridge.draft, placeholder: "Feedback to keep planning (optional)")
            HStack {
                Spacer()
                Button("Keep Planning") {
                    Task { await bridge.respond(.rejectPlan, text: bridge.draft) }
                }
                // A link request is approved by a click only, no shortcut.
                Button("Approve Plan") { Task { await bridge.respond(.approvePlan, explicit: true) } }
                    .keyboardShortcut(session.trusted ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ session: AgentSession) -> some View {
        Divider()
        if confirmingDisable {
            VStack(alignment: .leading, spacing: 6) {
                Text("Parrot will stay quiet for this \(session.agentName) session. Type \u{201C}enable parrot\u{201D} in the terminal to turn it back on.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmingDisable = false }
                    Button("Disable") { Task { await bridge.disableCurrentSession() } }
                }
            }
        } else {
            AgentBypassBadges(bridge: bridge)
            if !session.trusted {
                Label("Came by link, so details are hidden and choices are limited.", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Button("Disable Parrot for This Session") { confirmingDisable = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Bypass Badges

/// One badge per active bypass, shown whenever the panel is up (the panel
/// stays up while any bypass is on). Clicking revokes it.
struct AgentBypassBadges: View {
    @Bindable var bridge: AgentBridge

    var body: some View {
        ForEach(bridge.activeBypasses, id: \.sessionId) { entry in
            Button {
                bridge.setBypass(false, sessionId: entry.sessionId)
            } label: {
                Label("Bypass permissions active for \(entry.bypass.label), click to revoke", systemImage: "bolt.shield")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Parrot approves every tool call from this session until you revoke it or the CLI exits. If the CLI itself runs in bypass mode, change that in the terminal.")
        }
    }
}

// MARK: - Header

struct AgentPanelHeader: View {
    let session: AgentSession
    let queued: Int
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: session.agent == .claude ? "sparkles" : "terminal")
                .font(.title3)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.agentName).font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let title = session.title, !title.isEmpty {
                    Text(title).font(.caption).lineLimit(1)
                }
                if session.permissionMode == "bypassPermissions" {
                    Label("The CLI is running in bypass mode", systemImage: "bolt.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if queued > 0 {
                Text("\(queued) more waiting")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Hide the panel. The agent keeps waiting.")
        }
    }

    private var statusText: String {
        switch session.status {
        case .completed: return "Finished"
        case .permissionNeeded: return "Needs permission"
        case .question: return "Has a question"
        case .planReview: return "Plan ready"
        case .sending: return "Sending"
        case .error: return "Error"
        case .idle: return ""
        }
    }

    private var location: String {
        [session.project, session.branch.map { "on \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Summary

/// The agent's last message as Markdown, height capped.
struct AgentSummaryBubble: View {
    let session: AgentSession

    var body: some View {
        let text = session.message.isEmpty ? session.summary : session.message
        if !text.isEmpty {
            ScrollView {
                Text(Self.markdown(text))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Editor

/// The pending-send editor: dictations land here for review before sending.
struct AgentDraftEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56, maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
    }
}

// MARK: - Permission

/// A tool permission request. Speech only fills the editor; Allow and Deny
/// are always a click (or Cmd+Return for Allow on a trusted request).
/// Grants wider than once show exactly what they save, and are offered only
/// for inbox requests: Always Allow and Allow for This Session when Claude
/// suggested a narrow rule, Bypass when Parrot can watch the CLI process.
struct AgentPermissionView: View {
    @Bindable var bridge: AgentBridge
    let session: AgentSession
    @State private var confirmingBypass = false

    var body: some View {
        let permission = session.permission
        VStack(alignment: .leading, spacing: 8) {
            Text(permission?.summary ?? (session.trusted ? "Permission needed" : AgentSession.detailsUnavailable))
                .font(.subheadline.weight(.semibold))
            if let details = permission?.details, !details.isEmpty {
                ScrollView {
                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            }
            AgentDraftEditor(
                text: $bridge.draft,
                placeholder: session.trusted ? "Dictate or type a reason to deny (optional)" : "Explain a denial (optional)"
            )
            if bridge.draftSaysAllow {
                Text("Click Allow to approve. Speaking never approves on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if confirmingBypass {
                bypassConfirmation
            } else {
                grantRows
                HStack {
                    if bridge.canBypass(session) {
                        Button("Bypass for This Session…") { confirmingBypass = true }
                    }
                    Spacer()
                    Button("Deny") {
                        Task { await bridge.respond(.deny, text: AgentBridge.denialMessage(bridge.draft), explicit: true) }
                    }
                    // A link request is allowed by a click only, no shortcut.
                    Button("Allow") { Task { await bridge.respond(.allow, explicit: true) } }
                        .keyboardShortcut(session.trusted ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: session.requestId) { confirmingBypass = false }
    }

    /// Always Allow and Allow for This Session, each next to the exact rule
    /// it saves. Hidden when Claude offered nothing narrow enough.
    @ViewBuilder
    private var grantRows: some View {
        if let always = bridge.alwaysAllowRule(for: session) {
            grantRow(title: "Always Allow", rule: always.text, note: "Saved in this project's local Claude settings") {
                Task { await bridge.respond(.allowAlways, suggestionIndex: always.index, explicit: true) }
            }
        }
        if let rule = bridge.sessionRule(for: session) {
            grantRow(title: "Allow for This Session", rule: rule.text, note: "Until this Claude session ends") {
                Task { await bridge.respond(.allowSession, suggestionIndex: rule.index, explicit: true) }
            }
        }
    }

    private func grantRow(title: String, rule: String, note: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(title, action: action)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var bypassConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Bypass permissions for this session?", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
            Text("Parrot will approve every tool call from this \(session.agentName) session without asking, including shell commands and file writes, until you revoke it. It ends when the session ends or the CLI process exits. The badge stays at the bottom of this panel while it is on.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmingBypass = false }
                Button("Bypass Permissions", role: .destructive) {
                    confirmingBypass = false
                    Task { await bridge.respond(.bypass, explicit: true) }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
