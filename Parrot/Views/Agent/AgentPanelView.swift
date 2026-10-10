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
                        replyArea(session)
                    }
                case .plan:
                    planArea
                }
                footer(session)
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

    private var planArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentDraftEditor(text: $bridge.draft, placeholder: "Feedback to keep planning (optional)")
            HStack {
                Spacer()
                Button("Keep Planning") {
                    Task { await bridge.respond(.rejectPlan, text: bridge.draft) }
                }
                Button("Approve Plan") { Task { await bridge.respond(.approvePlan) } }
                    .keyboardShortcut(.return, modifiers: .command)
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
            HStack(spacing: 10) {
                if bridge.isBypassed(session.sessionId) {
                    Button {
                        bridge.setBypass(false, sessionId: session.sessionId)
                    } label: {
                        Label("Bypass permissions active, click to revoke", systemImage: "bolt.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Revoking stops Parrot approving for this session. If the CLI itself switched to bypass mode, change it in the terminal.")
                }
                Spacer()
                Button("Disable Parrot for This Session") { confirmingDisable = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

struct AgentPermissionView: View {
    @Bindable var bridge: AgentBridge
    let session: AgentSession

    var body: some View {
        let permission = session.permission
        VStack(alignment: .leading, spacing: 8) {
            Text(permission?.summary ?? "Permission needed").font(.subheadline.weight(.semibold))
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
            AgentDraftEditor(text: $bridge.draft, placeholder: "Say allow or deny, or explain a denial")
            HStack {
                Menu("More") {
                    if permission?.canUpdatePermissions ?? false {
                        Button("Always Allow") {
                            Task { await bridge.respond(.allowAlways, suggestionIndex: permission?.suggestions.isEmpty == false ? 0 : nil) }
                        }
                        Button("Allow for This Session") { Task { await bridge.respond(.allowSession) } }
                    }
                    Button("Bypass Permissions for This Session") { Task { await bridge.respond(.bypass) } }
                }
                .fixedSize()
                Spacer()
                Button("Deny") {
                    Task { await bridge.respond(.deny, text: bridge.draft) }
                }
                Button("Allow") { Task { await bridge.respond(.allow) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
