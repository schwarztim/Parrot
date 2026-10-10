import Foundation

// Wire format shared by Parrot and the `parrot-agent-hook` helper. [AGT]
//
// The helper is its own executable target and cannot import the app module,
// so this file exists twice, byte for byte: Parrot/Core/Agent/ and
// AgentHook/. HookPayloadTests fails when the copies differ. Edit both.
//
// The CLI side follows each vendor's hook reference (checked 2026-10-10):
//   Claude Code: https://code.claude.com/docs/en/hooks
//   Codex:       https://developers.openai.com/codex/hooks
// Field names below are the documented ones; nothing is guessed.
//
// Flow: the CLI runs the helper with the event JSON on stdin. The helper
// drops an `AgentInboxMessage` into Parrot's inbox, polls for an
// `AgentHookResponse` at `agent/responses/<requestId>.json`, and prints the
// decision JSON the CLI expects. No answer in time: it prints nothing and
// exits 0, so the CLI's own terminal prompt takes over.
//
// Trust: nothing in a message names a path. Both sides derive every file
// from the request id, which must match `^[A-Za-z0-9-]{8,64}$`. Folders are
// 0700 and owned by the user, files 0600. The `parrot://` fallback link
// carries only ids and names (URLs reach system logs), and anyone can open
// one, so the app treats link requests as untrusted.

// MARK: - Any JSON

/// Any JSON value, so tool inputs and permission suggestions pass through
/// unchanged when they are echoed back to the CLI.
enum HookJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HookJSON])
    case object([String: HookJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HookJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: HookJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out without a fraction (120000, not 120000.0).
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> HookJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [HookJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: HookJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Compact JSON text, keys sorted.
    var compactText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Agents and Events

/// The coding-agent CLIs the helper accepts as its one argument.
enum HookAgent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// What the CLI is waiting on.
enum HookEvent: String, Codable, Sendable {
    /// The turn finished (Stop). A reply continues the agent with that text.
    case stop
    /// A tool needs permission (PermissionRequest).
    case permission
    /// Claude's AskUserQuestion tool (PreToolUse).
    case question
    /// Claude's ExitPlanMode tool (PreToolUse).
    case plan
}

// MARK: - Hook Input (CLI to helper, stdin)

/// The event JSON a CLI writes to the hook's stdin. Only documented fields
/// are read; unknown fields are ignored.
struct HookInput: Decodable, Sendable {
    var sessionId: String
    var hookEventName: String
    var cwd: String?
    /// `default`, `plan`, `acceptEdits`, `auto`, `dontAsk` or `bypassPermissions`.
    var permissionMode: String?
    /// Stop: true when the turn is already continuing because of a Stop hook.
    var stopHookActive: Bool?
    /// Stop: the final assistant text of the turn (both CLIs).
    var lastAssistantMessage: String?
    var toolName: String?
    var toolInput: HookJSON?
    /// Claude PermissionRequest: suggested permission update entries.
    var permissionSuggestions: [HookJSON]?
    /// UserPromptSubmit: the submitted prompt.
    var prompt: String?
    /// Claude UserPromptSubmit and SessionStart: a custom session title.
    var sessionTitle: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case permissionMode = "permission_mode"
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
        case prompt
        case sessionTitle = "session_title"
    }

    /// The request this event becomes, or nil when Parrot has nothing to
    /// ask. Codex documents no question or plan tool, so only Claude's
    /// PreToolUse is read.
    func event(for agent: HookAgent) -> HookEvent? {
        switch hookEventName {
        case "Stop":
            return .stop
        case "PermissionRequest":
            return .permission
        case "PreToolUse" where agent == .claude:
            switch toolName {
            case "AskUserQuestion": return .question
            case "ExitPlanMode": return .plan
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Questions

/// One question from Claude's AskUserQuestion tool input.
struct HookQuestion: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable {
        var label: String
        var description: String?
    }

    var question: String
    var header: String?
    var options: [Option]
    var multiSelect: Bool

    init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }

    /// The questions in a tool input, or nil when it is not question data
    /// (the panel then shows the message as plain text).
    static func parse(_ toolInput: HookJSON?) -> [HookQuestion]? {
        guard let list = toolInput?["questions"], case .array = list,
              let data = try? JSONEncoder().encode(list),
              let questions = try? JSONDecoder().decode([HookQuestion].self, from: data),
              !questions.isEmpty
        else { return nil }
        return questions
    }
}

// MARK: - Permissions

/// A tool permission request, summarised for the panel.
struct HookPermission: Codable, Equatable, Sendable {
    var toolName: String
    /// One friendly line, for example "Run a shell command".
    var summary: String
    /// The command, path, pattern or arguments.
    var details: String
    /// Claude's `permission_suggestions`, echoed back for "always allow".
    var suggestions: [HookJSON]
    /// Claude can save rules and modes; Codex documents allow and deny only.
    var canUpdatePermissions: Bool

    init(agent: HookAgent, toolName: String, toolInput: HookJSON?, suggestions: [HookJSON]?) {
        self.toolName = toolName
        self.suggestions = suggestions ?? []
        self.canUpdatePermissions = agent == .claude
        let (friendly, details) = Self.describe(toolName: toolName, input: toolInput)
        self.summary = toolInput?["description"]?.stringValue ?? friendly
        self.details = details
    }

    /// Friendly text for the tools both CLIs document.
    static func describe(toolName: String, input: HookJSON?) -> (summary: String, details: String) {
        func field(_ key: String) -> String { input?[key]?.stringValue ?? "" }
        switch toolName {
        case "Bash", "PowerShell": return ("Run a shell command", field("command"))
        case "Edit", "MultiEdit": return ("Edit a file", field("file_path"))
        case "Write": return ("Write a file", field("file_path"))
        case "Read": return ("Read a file", field("file_path"))
        case "Glob": return ("Find files", field("pattern"))
        case "Grep": return ("Search file contents", field("pattern"))
        case "WebFetch": return ("Fetch a web page", field("url"))
        case "WebSearch": return ("Search the web", field("query"))
        case "apply_patch": return ("Apply a patch", field("command"))
        default:
            let details = input.map(\.compactText) ?? ""
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    return ("Use \(parts.dropFirst(2).joined(separator: "_")) from \(parts[1])", details)
                }
            }
            return ("Use \(toolName)", details)
        }
    }
}

// MARK: - Inbox Message (helper to app)

/// One file in Parrot's agent inbox. Only the helper writes it, into a
/// folder only the user can write.
struct AgentInboxMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A new request (or a newer one for the same session).
        case update
        /// The request is over: the helper timed out or the user went back
        /// to the terminal.
        case dismiss
    }

    var kind: Kind
    var agent: HookAgent
    var sessionId: String
    var requestId: String
    var event: HookEvent?
    /// One line for queue rows and the mini recorder.
    var summary: String?
    /// The agent's last message (Markdown), or the plan text.
    var message: String?
    /// True when the full message was too large to inline and sits in
    /// `agent/messages/<requestId>.md`.
    var messageInFile: Bool?
    var cwd: String?
    var project: String?
    var branch: String?
    var title: String?
    /// The helper's process id. Parrot drops the request when it exits.
    var hookPid: Int32?
    var permissionMode: String?
    var permission: HookPermission?
    var questions: [HookQuestion]?
    /// Unix seconds.
    var createdAt: Double

    /// Messages longer than this also go to a message file.
    static let inlineLimit = 60_000

    static func dismiss(agent: HookAgent, sessionId: String, requestId: String, hookPid: Int32?) -> AgentInboxMessage {
        AgentInboxMessage(
            kind: .dismiss, agent: agent, sessionId: sessionId, requestId: requestId,
            hookPid: hookPid, createdAt: Date().timeIntervalSince1970
        )
    }

    /// The update the helper sends for `event`.
    static func update(
        agent: HookAgent,
        event: HookEvent,
        input: HookInput,
        requestId: String,
        hookPid: Int32,
        branch: String?
    ) -> AgentInboxMessage {
        var message = AgentInboxMessage(
            kind: .update, agent: agent, sessionId: input.sessionId, requestId: requestId,
            event: event, cwd: input.cwd,
            project: input.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            branch: branch, title: input.sessionTitle, hookPid: hookPid,
            permissionMode: input.permissionMode, createdAt: Date().timeIntervalSince1970
        )
        switch event {
        case .stop:
            message.message = input.lastAssistantMessage
            message.summary = Self.firstLine(of: input.lastAssistantMessage) ?? "Finished its turn"
        case .permission:
            let permission = HookPermission(
                agent: agent, toolName: input.toolName ?? "tool",
                toolInput: input.toolInput, suggestions: input.permissionSuggestions
            )
            message.permission = permission
            message.summary = permission.summary
        case .question:
            let questions = HookQuestion.parse(input.toolInput)
            message.questions = questions
            message.summary = questions?.first?.question ?? "Has a question"
            if questions == nil { message.message = input.toolInput?.compactText }
        case .plan:
            message.message = input.toolInput?["plan"]?.stringValue
            message.summary = "Plan ready for review"
        }
        return message
    }

    /// The first non-empty line, trimmed to 140 characters.
    static func firstLine(of text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    /// True for ids the helper makes (UUID strings): letters, digits and
    /// dashes, 8 to 64 characters. Anything else is rejected everywhere.
    static func isValidRequestId(_ id: String) -> Bool {
        (8...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
    }
}

// MARK: - Fallback Link (helper to app, untrusted)

/// `parrot://agent-update?request=<id>&agent=<cli>&event=<kind>&project=<name>`,
/// the fallback when the inbox cannot be written (or agent-dismiss).
///
/// It carries no message, tool input, session id or path: URLs land in
/// system logs. Any page or process can open one, so the app shows such a
/// request with "details unavailable" and limits what it can answer.
struct AgentDeepLink: Equatable, Sendable {
    var kind: AgentInboxMessage.Kind
    var requestId: String
    var agent: HookAgent
    var event: HookEvent?
    var project: String?

    init(kind: AgentInboxMessage.Kind, requestId: String, agent: HookAgent, event: HookEvent?, project: String?) {
        self.kind = kind
        self.requestId = requestId
        self.agent = agent
        self.event = event
        self.project = project
    }

    init(message: AgentInboxMessage) {
        self.init(
            kind: message.kind, requestId: message.requestId, agent: message.agent,
            event: message.event, project: message.project.map { String($0.prefix(100)) }
        )
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "parrot"
        components.host = kind == .update ? "agent-update" : "agent-dismiss"
        var items = [
            URLQueryItem(name: "request", value: requestId),
            URLQueryItem(name: "agent", value: agent.rawValue),
        ]
        if let event { items.append(URLQueryItem(name: "event", value: event.rawValue)) }
        if let project { items.append(URLQueryItem(name: "project", value: project)) }
        components.queryItems = items
        return components.url
    }

    /// Parses a link. Nil unless the request id is valid, the agent is
    /// known and an update names its event. Other query items are ignored.
    init?(url: URL) {
        let host = url.host()?.lowercased()
        let kind: AgentInboxMessage.Kind
        switch host {
        case "agent-update": kind = .update
        case "agent-dismiss": kind = .dismiss
        default: return nil
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let requestId = value("request"), AgentInboxMessage.isValidRequestId(requestId),
              let agent = value("agent").flatMap(HookAgent.init(rawValue:))
        else { return nil }
        let event = value("event").flatMap(HookEvent.init(rawValue:))
        if kind == .update, event == nil { return nil }
        let project = value("project").map { String($0.prefix(100)) }
        self.init(kind: kind, requestId: requestId, agent: agent, event: event, project: project)
    }
}

// MARK: - Response (app to helper)

/// What Parrot writes to `agent/responses/<requestId>.json`.
struct AgentHookResponse: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        /// Stop: continue the agent with `text` as the next prompt.
        case reply
        /// Permission: allow once.
        case allow
        /// Permission: deny, telling the agent `text` when given.
        case deny
        /// Permission: allow and save the suggested rule (Claude).
        case allowAlways
        /// Permission: allow this tool for the rest of the session.
        case allowSession
        /// Permission: allow, and Parrot approves this session's later requests.
        case bypass
        /// Question: `answers` maps question text to the chosen labels.
        case answer
        /// Plan: approve.
        case approvePlan
        /// Plan: keep planning, with `text` as feedback.
        case rejectPlan
        /// Let the CLI's own terminal prompt take over.
        case dismiss
    }

    var requestId: String
    var action: Action
    var text: String?
    var answers: [String: [String]]?
    /// Which `permission_suggestions` entry "always allow" saves.
    var suggestionIndex: Int?

    init(requestId: String, action: Action, text: String? = nil, answers: [String: [String]]? = nil, suggestionIndex: Int? = nil) {
        self.requestId = requestId
        self.action = action
        self.text = text
        self.answers = answers
        self.suggestionIndex = suggestionIndex
    }
}

// MARK: - Decisions (helper to CLI, stdout)

/// Builds the JSON a CLI expects on stdout. Nil means print nothing and
/// exit 0, which both CLIs treat as "no decision".
enum HookDecision {

    static func output(agent: HookAgent, event: HookEvent, input: HookInput, response: AgentHookResponse) -> HookJSON? {
        switch event {
        case .stop:
            // Both CLIs: decision "block" with a reason continues the agent,
            // using the reason as the next prompt. The reason is required.
            guard response.action == .reply,
                  let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return .object(["decision": .string("block"), "reason": .string(text)])

        case .permission:
            return permission(agent: agent, input: input, response: response)

        case .question:
            guard agent == .claude, response.action == .answer,
                  let answers = response.answers, !answers.isEmpty
            else { return nil }
            // Claude: allow plus updatedInput that echoes the questions and
            // adds `answers` (question text to label; several labels joined
            // with commas). Allow alone is not enough for this tool.
            var updated = input.toolInput?.objectValue ?? [:]
            updated["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            return preToolUse(decision: "allow", reason: "Answered in Parrot", updatedInput: .object(updated))

        case .plan:
            guard agent == .claude else { return nil }
            switch response.action {
            case .approvePlan:
                return preToolUse(
                    decision: "allow", reason: "Approved in Parrot",
                    updatedInput: input.toolInput ?? .object([:])
                )
            case .rejectPlan:
                let feedback = response.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return preToolUse(
                    decision: "deny",
                    reason: (feedback?.isEmpty ?? true) ? "The user wants to keep planning." : feedback!,
                    updatedInput: nil
                )
            default:
                return nil
            }
        }
    }

    /// `{"decision":"block","reason":...}` for UserPromptSubmit, which both
    /// CLIs read as "do not send this prompt" and show the reason.
    static func blockPrompt(reason: String) -> HookJSON {
        .object(["decision": .string("block"), "reason": .string(reason)])
    }

    /// One line of JSON, keys sorted.
    static func encode(_ json: HookJSON) -> Data {
        Data(json.compactText.utf8)
    }

    private static func permission(agent: HookAgent, input: HookInput, response: AgentHookResponse) -> HookJSON? {
        var decision: [String: HookJSON]
        switch response.action {
        case .allow:
            decision = ["behavior": .string("allow")]
        case .deny:
            let message = response.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = [
                "behavior": .string("deny"),
                "message": .string((message?.isEmpty ?? true) ? "The user denied this in Parrot." : message!),
            ]
        case .allowAlways, .allowSession, .bypass:
            decision = ["behavior": .string("allow")]
            // Codex documents updatedPermissions as reserved (fails closed),
            // so it gets a plain allow; Parrot keeps any bypass itself.
            if agent == .claude, let update = permissionUpdate(input: input, response: response) {
                decision["updatedPermissions"] = .array([update])
            }
        default:
            return nil
        }
        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ])
    }

    /// Claude permission update entry for the richer allow choices.
    static func permissionUpdate(input: HookInput, response: AgentHookResponse) -> HookJSON? {
        let suggestions = input.permissionSuggestions ?? []
        let toolRule: HookJSON = .object(["toolName": .string(input.toolName ?? "")])
        func ruleSuggestion() -> [String: HookJSON]? {
            if let index = response.suggestionIndex, suggestions.indices.contains(index),
               let entry = suggestions[index].objectValue {
                return entry
            }
            return suggestions.lazy.compactMap(\.objectValue).first {
                $0["type"]?.stringValue == "addRules" && $0["behavior"]?.stringValue == "allow"
            }
        }
        switch response.action {
        case .allowAlways:
            // Echoing a received suggestion is the documented path. Without
            // one, save an allow rule for the whole tool in local settings.
            if let entry = ruleSuggestion() { return .object(entry) }
            guard input.toolName != nil else { return nil }
            return .object([
                "type": .string("addRules"), "rules": .array([toolRule]),
                "behavior": .string("allow"), "destination": .string("localSettings"),
            ])
        case .allowSession:
            if var entry = ruleSuggestion(), entry["type"]?.stringValue == "addRules" {
                entry["destination"] = .string("session")
                return .object(entry)
            }
            guard input.toolName != nil else { return nil }
            return .object([
                "type": .string("addRules"), "rules": .array([toolRule]),
                "behavior": .string("allow"), "destination": .string("session"),
            ])
        case .bypass:
            // A no-op unless the session was started with bypass available;
            // Parrot's own bypass marker covers the rest of the session.
            return .object([
                "type": .string("setMode"), "mode": .string("bypassPermissions"),
                "destination": .string("session"),
            ])
        default:
            return nil
        }
    }

    private static func preToolUse(decision: String, reason: String, updatedInput: HookJSON?) -> HookJSON {
        var output: [String: HookJSON] = [
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string(decision),
            "permissionDecisionReason": .string(reason),
        ]
        if let updatedInput { output["updatedInput"] = updatedInput }
        return .object(["hookSpecificOutput": .object(output)])
    }
}

// MARK: - Paths and Markers

/// Shared state the app writes for the helper: is the feature on, which
/// process is Parrot, how long to wait.
struct AgentHookState: Codable, Equatable, Sendable {
    var enabled: Bool
    var appPid: Int32
    /// Seconds the helper waits for an answer.
    var responseTimeout: Double
}

/// Where the helper and the app meet.
///
/// The root defaults to `~/Library/Application Support/Parrot/` (the app's
/// `AppPaths` root); `PARROT_AGENT_ROOT` overrides it for tests. Session
/// markers live in the per-user temp folder, `PARROT_AGENT_CONTROL_DIR`
/// overrides it. Every folder is checked with `secureDirectory` before use.
struct AgentHookPaths: Equatable, Sendable {
    var root: URL
    var controlDir: URL

    static let rootVariable = "PARROT_AGENT_ROOT"
    static let controlVariable = "PARROT_AGENT_CONTROL_DIR"
    static let timeoutVariable = "PARROT_AGENT_TIMEOUT"
    static let openerVariable = "PARROT_AGENT_URL_OPENER"

    init(root: URL, controlDir: URL) {
        self.root = root
        self.controlDir = controlDir
    }

    static func resolve(environment: [String: String]) -> AgentHookPaths {
        let root = environment[rootVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Parrot", isDirectory: true)
        let control = environment[controlVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultControlDir
        return AgentHookPaths(root: root, controlDir: control)
    }

    /// `parrot-agent/` in the per-user temp folder. Read from the system
    /// (`_CS_DARWIN_USER_TEMP_DIR`, what `temporaryDirectory` normally
    /// returns) rather than `TMPDIR`, so the app and a hook started from any
    /// shell agree on it.
    static var defaultControlDir: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let temp = length > 0 && length <= buffer.count
            ? URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            : FileManager.default.temporaryDirectory
        return temp.appendingPathComponent("parrot-agent", isDirectory: true)
    }

    var agentDir: URL { root.appendingPathComponent("agent", isDirectory: true) }
    var inbox: URL { agentDir.appendingPathComponent("inbox", isDirectory: true) }
    var responses: URL { agentDir.appendingPathComponent("responses", isDirectory: true) }
    var messages: URL { agentDir.appendingPathComponent("messages", isDirectory: true) }
    var stateFile: URL { agentDir.appendingPathComponent("state.json") }

    /// `responses/<requestId>.json`, or nil when the id is not valid or the
    /// path would leave the responses folder.
    func responseFile(requestId: String) -> URL? {
        Self.file(named: requestId, extension: "json", in: responses)
    }

    /// `messages/<requestId>.md`, with the same checks.
    func messageFile(requestId: String) -> URL? {
        Self.file(named: requestId, extension: "md", in: messages)
    }

    private static func file(named requestId: String, extension ext: String, in directory: URL) -> URL? {
        guard AgentInboxMessage.isValidRequestId(requestId) else { return nil }
        let file = directory.appendingPathComponent("\(requestId).\(ext)").standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return nil }
        return file
    }

    /// Present: the helper exits at once for this session.
    func disabledMarker(sessionId: String) -> URL {
        controlDir.appendingPathComponent("disabled-" + Self.safeName(sessionId))
    }

    /// Present: the helper allows this session's permission requests itself.
    func bypassMarker(sessionId: String) -> URL {
        controlDir.appendingPathComponent("bypass-" + Self.safeName(sessionId))
    }

    /// Letters, digits, dot, dash and underscore; anything else becomes `_`.
    static func safeName(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(id.prefix(128).map { allowed.contains($0) ? $0 : "_" })
        return mapped.isEmpty || mapped.allSatisfy({ $0 == "." }) ? "_" : mapped
    }

    // MARK: Folder and File Safety

    enum DirectoryCheck: Equatable, Sendable {
        case missing
        /// A real folder owned by this user, mode 0700.
        case secure
        /// A symlink, not a folder, owned by someone else, or unfixable.
        case insecure
    }

    /// Checks `directory` without following a symlink: it must be a real
    /// folder owned by this user. Group and other access on a folder the
    /// user owns is removed (0700). With `create`, a missing folder is made
    /// 0700 (its parent must exist).
    @discardableResult
    static func secureDirectory(_ directory: URL, create: Bool) -> DirectoryCheck {
        let path = directory.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { return .insecure }
            guard create else { return .missing }
            if mkdir(path, 0o700) != 0, errno != EEXIST { return .insecure }
            guard lstat(path, &info) == 0 else { return .insecure }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return .insecure }
        if info.st_mode & 0o077 != 0 {
            guard chmod(path, 0o700) == 0 else { return .insecure }
        }
        return .secure
    }

    /// Writes `data` to a hidden temp file created with `permissions`
    /// (0600 unless given), then renames it into place, so a reader never
    /// sees half a file and nobody else can read it. A missing parent folder
    /// is created 0700.
    static func writeAtomically(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        func failure(_ code: Int32) -> Error {
            CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else { throw failure(errno) }
        var code: Int32 = 0
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    code = errno
                    return
                }
                offset += written
            }
        }
        // The umask may have cleared bits the caller asked for.
        if code == 0, fchmod(descriptor, permissions) != 0 { code = errno }
        close(descriptor)
        if code == 0, rename(temp.path, url.path) != 0 { code = errno }
        if code != 0 {
            unlink(temp.path)
            throw failure(code)
        }
    }

    /// True for a regular file (not a symlink) owned by this user.
    static func isPrivateFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }
}

/// True when a process with this id exists (EPERM still means it exists).
func agentHookProcessIsAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

// MARK: - Session Control Phrases

enum AgentHookPhrases {
    /// What the user types in the terminal to turn Parrot back on for a
    /// session they disabled: "enable parrot", "parrot on" or "/parrot".
    static func isEnable(_ prompt: String) -> Bool {
        let words = prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/")).inverted)
            .filter { !$0.isEmpty }
        return words == ["enable", "parrot"] || words == ["parrot", "on"] || words == ["/parrot"]
            || words == ["turn", "on", "parrot"] || words == ["turn", "parrot", "on"]
    }
}

// MARK: - Git Branch

enum AgentHookGit {
    /// The checked-out branch for `cwd`, read from `.git/HEAD` (worktrees
    /// included) without running git. A detached head gives a short hash.
    static func branch(at cwd: String) -> String? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var head = dotGit.appendingPathComponent("HEAD")
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
                    let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitDir = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path, isDirectory: true)
                        : directory.appendingPathComponent(path, isDirectory: true)
                    head = gitDir.appendingPathComponent("HEAD")
                }
                guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
                return line.isEmpty ? nil : String(line.prefix(7))
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
