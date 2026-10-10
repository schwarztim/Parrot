import XCTest
@testable import Parrot

/// Decodes the hook payloads Claude Code and Codex document, and encodes
/// the decisions they expect back. Fixtures follow the examples in
/// https://code.claude.com/docs/en/hooks and
/// https://developers.openai.com/codex/hooks (synthetic values only).
final class HookPayloadTests: XCTestCase {

    // MARK: - Fixtures

    static let claudeStop = """
        {
          "session_id": "abc123",
          "transcript_path": "~/.claude/projects/x/00893aaf.jsonl",
          "cwd": "/Users/example/my-project",
          "permission_mode": "default",
          "hook_event_name": "Stop",
          "stop_hook_active": true,
          "last_assistant_message": "I've completed the refactoring.\\nHere's a summary...",
          "background_tasks": [],
          "session_crons": []
        }
        """

    static let claudePermission = """
        {
          "session_id": "abc123",
          "transcript_path": "/Users/example/.claude/projects/x/00893aaf.jsonl",
          "cwd": "/Users/example/my-project",
          "permission_mode": "default",
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "tool_input": {
            "command": "rm -rf node_modules",
            "description": "Remove node_modules directory"
          },
          "permission_suggestions": [
            {
              "type": "addRules",
              "rules": [{ "toolName": "Bash", "ruleContent": "rm -rf node_modules" }],
              "behavior": "allow",
              "destination": "localSettings"
            }
          ]
        }
        """

    static let claudeQuestion = """
        {
          "session_id": "abc123",
          "cwd": "/Users/example/my-project",
          "permission_mode": "default",
          "hook_event_name": "PreToolUse",
          "tool_name": "AskUserQuestion",
          "tool_use_id": "toolu_01ABC",
          "tool_input": {
            "questions": [
              {
                "question": "Which framework?",
                "header": "Framework",
                "options": [
                  {"label": "React", "description": "Component library"},
                  {"label": "Vue", "description": "Progressive framework"}
                ],
                "multiSelect": false
              },
              {
                "question": "Which extras?",
                "header": "Extras",
                "options": [{"label": "Router"}, {"label": "State"}, {"label": "Tests"}],
                "multiSelect": true
              }
            ]
          }
        }
        """

    static let claudePlan = """
        {
          "session_id": "abc123",
          "cwd": "/Users/example/my-project",
          "permission_mode": "plan",
          "hook_event_name": "PreToolUse",
          "tool_name": "ExitPlanMode",
          "tool_use_id": "toolu_01DEF",
          "tool_input": {
            "plan": "## Refactor auth\\n1. Extract the session type",
            "planFilePath": "/Users/example/.claude/plans/refactor-auth.md"
          }
        }
        """

    static let codexStop = """
        {
          "session_id": "019a-codex",
          "transcript_path": null,
          "cwd": "/Users/example/repo",
          "hook_event_name": "Stop",
          "model": "gpt-5-codex",
          "turn_id": "turn-7",
          "permission_mode": "default",
          "stop_hook_active": false,
          "last_assistant_message": null
        }
        """

    static let codexPermission = """
        {
          "session_id": "019a-codex",
          "transcript_path": "/Users/example/.codex/sessions/x.jsonl",
          "cwd": "/Users/example/repo",
          "hook_event_name": "PermissionRequest",
          "model": "gpt-5-codex",
          "turn_id": "turn-8",
          "permission_mode": "default",
          "tool_name": "Bash",
          "tool_input": {"command": "git push", "description": null}
        }
        """

    private func decode(_ json: String) throws -> HookInput {
        try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
    }

    private func json(_ text: String) throws -> HookJSON {
        try JSONDecoder().decode(HookJSON.self, from: Data(text.utf8))
    }

    // MARK: - Shared File

    func testHelperAndAppShareOneProtocolFile() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try Data(contentsOf: repo.appendingPathComponent("Parrot/Core/Agent/AgentHookProtocol.swift"))
        let helper = try Data(contentsOf: repo.appendingPathComponent("AgentHook/AgentHookProtocol.swift"))
        XCTAssertEqual(app, helper, "AgentHook/AgentHookProtocol.swift must be a byte-identical copy")
    }

    // MARK: - Decoding

    func testDecodesClaudeStop() throws {
        let input = try decode(Self.claudeStop)
        XCTAssertEqual(input.sessionId, "abc123")
        XCTAssertEqual(input.event(for: .claude), .stop)
        XCTAssertEqual(input.stopHookActive, true)

        let message = AgentInboxMessage.update(
            agent: .claude, event: .stop, input: input, requestId: "r1",
            hookPid: 42, branch: "main"
        )
        XCTAssertEqual(message.kind, .update)
        XCTAssertEqual(message.project, "my-project")
        XCTAssertEqual(message.summary, "I've completed the refactoring.")
        XCTAssertEqual(message.message, "I've completed the refactoring.\nHere's a summary...")
        XCTAssertEqual(message.branch, "main")
        XCTAssertEqual(message.hookPid, 42)
    }

    func testDecodesClaudePermissionRequest() throws {
        let input = try decode(Self.claudePermission)
        XCTAssertEqual(input.event(for: .claude), .permission)
        let message = AgentInboxMessage.update(
            agent: .claude, event: .permission, input: input, requestId: "r2",
            hookPid: 1, branch: nil
        )
        let permission = try XCTUnwrap(message.permission)
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertEqual(permission.summary, "Remove node_modules directory")
        XCTAssertEqual(permission.details, "rm -rf node_modules")
        XCTAssertEqual(permission.suggestions.count, 1)
        XCTAssertTrue(permission.canUpdatePermissions)
    }

    func testDecodesClaudeQuestionsAndPlan() throws {
        let question = try decode(Self.claudeQuestion)
        XCTAssertEqual(question.event(for: .claude), .question)
        let questions = try XCTUnwrap(HookQuestion.parse(question.toolInput))
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].header, "Framework")
        XCTAssertEqual(questions[0].options.map(\.label), ["React", "Vue"])
        XCTAssertFalse(questions[0].multiSelect)
        XCTAssertTrue(questions[1].multiSelect)
        XCTAssertNil(questions[1].options[0].description)

        let plan = try decode(Self.claudePlan)
        XCTAssertEqual(plan.event(for: .claude), .plan)
        let message = AgentInboxMessage.update(
            agent: .claude, event: .plan, input: plan, requestId: "r3",
            hookPid: 1, branch: nil
        )
        XCTAssertEqual(message.message, "## Refactor auth\n1. Extract the session type")
        XCTAssertEqual(message.permissionMode, "plan")
    }

    func testNonQuestionToolInputIsPlainText() throws {
        XCTAssertNil(HookQuestion.parse(try json(#"{"questions": "not a list"}"#)))
        XCTAssertNil(HookQuestion.parse(try json(#"{"questions": []}"#)))
        XCTAssertNil(HookQuestion.parse(nil))
    }

    func testDecodesCodexPayloads() throws {
        let stop = try decode(Self.codexStop)
        XCTAssertEqual(stop.event(for: .codex), .stop)
        XCTAssertNil(stop.lastAssistantMessage)
        let message = AgentInboxMessage.update(
            agent: .codex, event: .stop, input: stop, requestId: "r4",
            hookPid: 1, branch: nil
        )
        XCTAssertEqual(message.summary, "Finished its turn")
        XCTAssertNil(message.message)

        let permission = try decode(Self.codexPermission)
        XCTAssertEqual(permission.event(for: .codex), .permission)
        let request = HookPermission(
            agent: .codex, toolName: "Bash", toolInput: permission.toolInput, suggestions: nil
        )
        XCTAssertEqual(request.summary, "Run a shell command")
        XCTAssertEqual(request.details, "git push")
        XCTAssertFalse(request.canUpdatePermissions)
    }

    func testCodexHasNoQuestionOrPlanEvents() throws {
        let question = try decode(Self.claudeQuestion)
        XCTAssertNil(question.event(for: .codex))
        let other = try decode(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash"}"#)
        XCTAssertNil(other.event(for: .claude))
    }

    func testFriendlyToolSummaries() {
        XCTAssertEqual(HookPermission.describe(toolName: "Edit", input: .object(["file_path": .string("/a.swift")])).summary, "Edit a file")
        XCTAssertEqual(HookPermission.describe(toolName: "WebFetch", input: .object(["url": .string("https://example.com")])).details, "https://example.com")
        XCTAssertEqual(HookPermission.describe(toolName: "mcp__memory__create_entities", input: nil).summary, "Use create_entities from memory")
        XCTAssertEqual(HookPermission.describe(toolName: "apply_patch", input: .object(["command": .string("*** Begin Patch")])).summary, "Apply a patch")
    }

    func testJSONPassThroughKeepsNumbersAndBools() throws {
        // Keys sorted, as compactText writes them.
        let original = #"{"command":"npm test","ratio":0.5,"run_in_background":false,"tags":["a",null],"timeout":120000}"#
        XCTAssertEqual(try json(original).compactText, original)
    }

    // MARK: - Decisions

    private func output(_ agent: HookAgent, _ event: HookEvent, _ fixture: String, _ response: AgentHookResponse) throws -> String? {
        HookDecision.output(agent: agent, event: event, input: try decode(fixture), response: response)?.compactText
    }

    func testStopReplyBlocksWithReason() throws {
        let reply = AgentHookResponse(requestId: "r", action: .reply, text: "  Now run the tests  ")
        XCTAssertEqual(try output(.claude, .stop, Self.claudeStop, reply), #"{"decision":"block","reason":"Now run the tests"}"#)
        XCTAssertEqual(try output(.codex, .stop, Self.codexStop, reply), #"{"decision":"block","reason":"Now run the tests"}"#)
        // The reason is required, so an empty reply lets the agent stop.
        XCTAssertNil(try output(.claude, .stop, Self.claudeStop, AgentHookResponse(requestId: "r", action: .reply, text: " ")))
        XCTAssertNil(try output(.claude, .stop, Self.claudeStop, AgentHookResponse(requestId: "r", action: .dismiss)))
    }

    func testPermissionAllowAndDeny() throws {
        let allow = AgentHookResponse(requestId: "r", action: .allow)
        let expectedAllow = #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        XCTAssertEqual(try output(.claude, .permission, Self.claudePermission, allow), expectedAllow)
        XCTAssertEqual(try output(.codex, .permission, Self.codexPermission, allow), expectedAllow)

        let deny = AgentHookResponse(requestId: "r", action: .deny, text: "Not on main")
        XCTAssertEqual(
            try output(.codex, .permission, Self.codexPermission, deny),
            #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Not on main"},"hookEventName":"PermissionRequest"}}"#
        )
        let bareDeny = try XCTUnwrap(try output(.claude, .permission, Self.claudePermission, AgentHookResponse(requestId: "r", action: .deny)))
        XCTAssertTrue(bareDeny.contains(#""message":"The user denied this in Parrot.""#))
        XCTAssertNil(try output(.claude, .permission, Self.claudePermission, AgentHookResponse(requestId: "r", action: .dismiss)))
    }

    func testClaudeAlwaysAllowEchoesTheSuggestion() throws {
        let text = try XCTUnwrap(try output(.claude, .permission, Self.claudePermission, AgentHookResponse(requestId: "r", action: .allowAlways, suggestionIndex: 0)))
        XCTAssertEqual(
            text,
            #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"rm -rf node_modules","toolName":"Bash"}],"type":"addRules"}]},"hookEventName":"PermissionRequest"}}"#
        )
    }

    func testClaudeSessionAllowAndBypassUpdates() throws {
        let input = try decode(Self.claudePermission)
        let session = HookDecision.permissionUpdate(input: input, response: AgentHookResponse(requestId: "r", action: .allowSession))
        XCTAssertEqual(session?["destination"]?.stringValue, "session")
        XCTAssertEqual(session?["type"]?.stringValue, "addRules")

        // Bypass is Parrot's own marker: the CLI's mode is never switched.
        XCTAssertNil(HookDecision.permissionUpdate(input: input, response: AgentHookResponse(requestId: "r", action: .bypass)))
        let bypassOutput = try XCTUnwrap(try output(.claude, .permission, Self.claudePermission, AgentHookResponse(requestId: "r", action: .bypass)))
        XCTAssertEqual(bypassOutput, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)

        // Without an index, "always allow" skips a mode suggestion and
        // saves the first narrow allow rule.
        var mixed = input
        mixed.permissionSuggestions = [
            .object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")]),
        ] + (input.permissionSuggestions ?? [])
        let rule = HookDecision.permissionUpdate(input: mixed, response: AgentHookResponse(requestId: "r", action: .allowAlways))
        XCTAssertEqual(rule?["type"]?.stringValue, "addRules")
        XCTAssertEqual(rule?["destination"]?.stringValue, "localSettings")

        // No suggestions (file edit dialogs send none): nothing is made up,
        // so the decision is a plain allow.
        var edit = input
        edit.toolName = "Edit"
        edit.permissionSuggestions = nil
        XCTAssertNil(HookDecision.permissionUpdate(input: edit, response: AgentHookResponse(requestId: "r", action: .allowAlways)))
        XCTAssertNil(HookDecision.permissionUpdate(input: edit, response: AgentHookResponse(requestId: "r", action: .allowSession)))
    }

    // MARK: - Narrow Grants

    private func rule(_ tool: String, _ content: String?, destination: String = "localSettings", type: String = "addRules") -> HookJSON {
        var rule: [String: HookJSON] = ["toolName": .string(tool)]
        if let content { rule["ruleContent"] = .string(content) }
        return .object([
            "type": .string(type), "behavior": .string("allow"),
            "destination": .string(destination), "rules": .array([.object(rule)]),
        ])
    }

    func testOnlyNarrowRulesCanBeAlwaysAllowed() {
        let specific: [(String, String?)] = [
            ("Bash", "rm -rf node_modules"), ("Bash", "npm run test:*"), ("Bash", "git commit *"),
            ("Bash", "ls"), ("Edit", "src/**"), ("WebFetch", "domain:example.com"), ("Read", "/Users/example/a.swift"),
        ]
        for (tool, content) in specific {
            XCTAssertTrue(HookPermissionRules.isAlwaysAllowable(rule(tool, content)), "\(tool)(\(content ?? ""))")
        }
        let broad: [(String, String?)] = [
            ("Bash", nil), ("Bash", "*"), ("Bash", ""), ("Bash", "npm:*"), ("Bash", "git *"), ("Bash", "rm * -rf"),
            ("Edit", nil), ("Edit", "**"), ("Read", "/**"), ("mcp__memory__create", nil), ("mcp__memory__*", "x"),
        ]
        for (tool, content) in broad {
            XCTAssertFalse(HookPermissionRules.isAlwaysAllowable(rule(tool, content)), "\(tool)(\(content ?? ""))")
        }
        // Mode changes, directories, other destinations and deny rules never qualify.
        XCTAssertFalse(HookPermissionRules.isAlwaysAllowable(.object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("localSettings")])))
        XCTAssertFalse(HookPermissionRules.isAlwaysAllowable(.object(["type": .string("addDirectories"), "directories": .array([.string("/")]), "destination": .string("localSettings")])))
        XCTAssertFalse(HookPermissionRules.isAlwaysAllowable(rule("Bash", "npm test", destination: "userSettings")))
        XCTAssertFalse(HookPermissionRules.isAlwaysAllowable(rule("Bash", "npm test", type: "replaceRules")))
        // Session grants allow any destination but are just as narrow.
        XCTAssertTrue(HookPermissionRules.isSessionAllowable(rule("Bash", "npm test", destination: "userSettings")))
        XCTAssertFalse(HookPermissionRules.isSessionAllowable(rule("Bash", "npm:*", destination: "session")))
    }

    func testRuleTextIsExactlyWhatIsSaved() {
        XCTAssertEqual(HookPermissionRules.text(of: rule("Bash", "npm run test:*")), "Bash(npm run test:*)")
        XCTAssertEqual(HookPermissionRules.text(of: rule("Edit", nil)), "Edit")
        XCTAssertNil(HookPermissionRules.text(of: .object(["type": .string("setMode"), "mode": .string("plan")])))
    }

    func testBroadSuggestionsGetAPlainAllow() throws {
        var input = try decode(Self.claudePermission)
        input.permissionSuggestions = [rule("Bash", nil), rule("Bash", "npm:*")]
        XCTAssertNil(HookPermissionRules.alwaysAllowIndex(in: input.permissionSuggestions!))
        // Even an index pointing at a broad suggestion saves nothing.
        for action in [AgentHookResponse.Action.allowAlways, .allowSession] {
            for index in [0, 1, nil] {
                XCTAssertNil(HookDecision.permissionUpdate(input: input, response: AgentHookResponse(requestId: "r", action: action, suggestionIndex: index)))
            }
        }
        input.permissionSuggestions?.append(rule("Bash", "npm run lint"))
        XCTAssertEqual(HookPermissionRules.alwaysAllowIndex(in: input.permissionSuggestions!), 2)
        XCTAssertEqual(
            HookDecision.permissionUpdate(input: input, response: AgentHookResponse(requestId: "r", action: .allowAlways))?["rules"]?.arrayValue?.first?["ruleContent"]?.stringValue,
            "npm run lint"
        )
    }

    func testCodexRicherAllowsDegradeToPlainAllow() throws {
        let plain = #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        for action in [AgentHookResponse.Action.allowAlways, .allowSession, .bypass] {
            XCTAssertEqual(try output(.codex, .permission, Self.codexPermission, AgentHookResponse(requestId: "r", action: action)), plain)
        }
    }

    func testQuestionAnswersEchoQuestionsAndAddAnswers() throws {
        let response = AgentHookResponse(
            requestId: "r", action: .answer,
            answers: ["Which framework?": ["React"], "Which extras?": ["Router", "Tests"]]
        )
        let result = try XCTUnwrap(HookDecision.output(agent: .claude, event: .question, input: try decode(Self.claudeQuestion), response: response))
        let specific = try XCTUnwrap(result["hookSpecificOutput"])
        XCTAssertEqual(specific["hookEventName"]?.stringValue, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"]?.stringValue, "allow")
        let updated = try XCTUnwrap(specific["updatedInput"])
        XCTAssertEqual(updated["questions"]?.arrayValue?.count, 2)
        XCTAssertEqual(updated["answers"]?["Which framework?"]?.stringValue, "React")
        XCTAssertEqual(updated["answers"]?["Which extras?"]?.stringValue, "Router, Tests")

        XCTAssertNil(HookDecision.output(agent: .claude, event: .question, input: try decode(Self.claudeQuestion), response: AgentHookResponse(requestId: "r", action: .answer, answers: [:])))
    }

    func testPlanApproveAndReject() throws {
        let approve = try XCTUnwrap(HookDecision.output(agent: .claude, event: .plan, input: try decode(Self.claudePlan), response: AgentHookResponse(requestId: "r", action: .approvePlan)))
        XCTAssertEqual(approve["hookSpecificOutput"]?["permissionDecision"]?.stringValue, "allow")
        XCTAssertEqual(approve["hookSpecificOutput"]?["updatedInput"]?["planFilePath"]?.stringValue, "/Users/example/.claude/plans/refactor-auth.md")

        let reject = try XCTUnwrap(try output(.claude, .plan, Self.claudePlan, AgentHookResponse(requestId: "r", action: .rejectPlan, text: "Split step one")))
        XCTAssertEqual(reject, #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Split step one"}}"#)
    }

    func testResponseRoundTrip() throws {
        let response = AgentHookResponse(requestId: "r9", action: .answer, answers: ["Q": ["A"]])
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(AgentHookResponse.self, from: data), response)
    }

    // MARK: - Links, Phrases, Paths

    static let requestId = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    func testDeepLinkCarriesOnlyIdsAndNames() throws {
        let input = try decode(Self.claudePermission)
        var message = AgentInboxMessage.update(
            agent: .claude, event: .permission, input: input, requestId: Self.requestId,
            hookPid: 7, branch: "main"
        )
        message.message = "secret source code and API_KEY=sk-test-123"
        let url = try XCTUnwrap(AgentDeepLink(message: message).url)
        XCTAssertEqual(url.scheme, "parrot")
        XCTAssertEqual(url.host(), "agent-update")
        XCTAssertEqual(URLRoute(url), .agent(url))

        // Exactly the request id, agent, event, project name and session id;
        // nothing from the message, the tool input, the mode or any path.
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).sorted()
        XCTAssertEqual(names, ["agent", "event", "project", "request", "session"])
        for secret in ["rm -rf", "node_modules", "secret", "API_KEY", "/Users/example", "main", "default", "Remove"] {
            XCTAssertFalse(url.absoluteString.contains(secret), "link leaks \(secret)")
        }

        let link = try XCTUnwrap(AgentDeepLink(url: url))
        XCTAssertEqual(link, AgentDeepLink(kind: .update, requestId: Self.requestId, agent: .claude, event: .permission, project: "my-project", sessionId: "abc123"))

        let dismiss = AgentDeepLink(message: .dismiss(agent: .codex, sessionId: "s", requestId: Self.requestId, hookPid: nil))
        XCTAssertEqual(dismiss.url?.host(), "agent-dismiss")
        XCTAssertEqual(AgentDeepLink(url: try XCTUnwrap(dismiss.url))?.kind, .dismiss)
    }

    func testDeepLinkRejectsBadRequestsAndIgnoresPaths() throws {
        let bad = [
            "parrot://agent-update?request=../../etc/passwd&agent=claude&event=stop",
            "parrot://agent-update?request=short&agent=claude&event=stop",
            "parrot://agent-update?request=\(String(repeating: "a", count: 65))&agent=claude&event=stop",
            "parrot://agent-update?request=\(Self.requestId)&agent=grok&event=stop",
            "parrot://agent-update?request=\(Self.requestId)&agent=claude",
            "parrot://agent-wake?request=\(Self.requestId)&agent=claude&event=stop",
        ]
        for text in bad {
            XCTAssertNil(AgentDeepLink(url: try XCTUnwrap(URL(string: text))), text)
        }
        // Extra items such as a response path or a mode are ignored, never
        // used; a session id with a path in it is dropped.
        let crafted = try XCTUnwrap(URL(string: "parrot://agent-update?request=\(Self.requestId)&agent=codex&event=stop&responseFile=/tmp/evil.json&payload=xyz&permissionMode=bypassPermissions&session=../../x"))
        XCTAssertEqual(AgentDeepLink(url: crafted), AgentDeepLink(kind: .update, requestId: Self.requestId, agent: .codex, event: .stop, project: nil))
        XCTAssertNil(AgentDeepLink(url: crafted)?.sessionId)
    }

    func testProcessLookupFindsTheParent() throws {
        let me = try XCTUnwrap(AgentHookProcess.parentAndName(of: getpid()))
        XCTAssertEqual(me.parent, getppid())
        XCTAssertFalse(me.name.isEmpty)
        XCTAssertNil(AgentHookProcess.parentAndName(of: 999_999))
    }

    func testRequestIdsAndDerivedPaths() {
        XCTAssertTrue(AgentInboxMessage.isValidRequestId(UUID().uuidString))
        XCTAssertTrue(AgentInboxMessage.isValidRequestId("abcd1234"))
        XCTAssertFalse(AgentInboxMessage.isValidRequestId("abc123"))
        XCTAssertFalse(AgentInboxMessage.isValidRequestId("../../x/../y"))
        XCTAssertFalse(AgentInboxMessage.isValidRequestId("abcd_1234"))
        XCTAssertFalse(AgentInboxMessage.isValidRequestId("abcd1234é"))
        XCTAssertFalse(AgentInboxMessage.isValidRequestId(String(repeating: "a", count: 65)))

        let paths = AgentHookPaths(root: URL(fileURLWithPath: "/r"), controlDir: URL(fileURLWithPath: "/c"))
        XCTAssertEqual(paths.responseFile(requestId: Self.requestId)?.path, "/r/agent/responses/\(Self.requestId).json")
        XCTAssertEqual(paths.messageFile(requestId: Self.requestId)?.path, "/r/agent/messages/\(Self.requestId).md")
        XCTAssertNil(paths.responseFile(requestId: "../../../tmp/evil"))
        XCTAssertNil(paths.responseFile(requestId: ""))
    }

    func testFilesAre0600AndFoldersAre0700() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("agent/inbox/x.json")
        try AgentHookPaths.writeAtomically(Data("{}".utf8), to: file)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["x.json"], "no temp file left")
        try AgentHookPaths.writeAtomically(Data("{\"a\":1}".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"a\":1}")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertTrue(AgentHookPaths.isPrivateFile(file))

        let shared = root.appendingPathComponent("shared.json")
        try AgentHookPaths.writeAtomically(Data(), to: shared, permissions: 0o644)
        XCTAssertEqual(try mode(shared), 0o644)
    }

    func testSecureDirectoryChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = root.appendingPathComponent("fresh")
        XCTAssertEqual(AgentHookPaths.secureDirectory(fresh, create: false), .missing)
        XCTAssertEqual(AgentHookPaths.secureDirectory(fresh, create: true), .secure)
        XCTAssertEqual(try mode(fresh), 0o700)

        let open = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        XCTAssertEqual(AgentHookPaths.secureDirectory(open, create: false), .secure)
        XCTAssertEqual(try mode(open), 0o700, "group and other access removed")

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
        XCTAssertEqual(AgentHookPaths.secureDirectory(link, create: true), .insecure)

        let file = root.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertEqual(AgentHookPaths.secureDirectory(file, create: true), .insecure)
        XCTAssertFalse(AgentHookPaths.isPrivateFile(link))
    }

    func testDefaultControlDirIsPerUserTemp() {
        let control = AgentHookPaths.defaultControlDir
        XCTAssertEqual(control.lastPathComponent, "parrot-agent")
        XCTAssertFalse(control.path.hasPrefix("/tmp/"))
        XCTAssertTrue(control.path.contains("/T/") || control.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testEnablePhrases() {
        XCTAssertTrue(AgentHookPhrases.isEnable("enable parrot"))
        XCTAssertTrue(AgentHookPhrases.isEnable("  Enable Parrot. "))
        XCTAssertTrue(AgentHookPhrases.isEnable("/parrot"))
        XCTAssertTrue(AgentHookPhrases.isEnable("parrot on"))
        XCTAssertFalse(AgentHookPhrases.isEnable("enable parrot and fix the build"))
        XCTAssertFalse(AgentHookPhrases.isEnable("parrot"))
    }

    func testSafeNamesAndMarkers() {
        XCTAssertEqual(AgentHookPaths.safeName("abc-123_x.y"), "abc-123_x.y")
        XCTAssertEqual(AgentHookPaths.safeName("../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(AgentHookPaths.safeName(".."), "_")
        XCTAssertEqual(AgentHookPaths.safeName(""), "_")
        let paths = AgentHookPaths(root: URL(fileURLWithPath: "/r"), controlDir: URL(fileURLWithPath: "/c"))
        XCTAssertEqual(paths.disabledMarker(sessionId: "a/b").path, "/c/disabled-a_b")
        XCTAssertEqual(paths.bypassMarker(sessionId: "s1").path, "/c/bypass-s1")
        XCTAssertEqual(paths.inbox.path, "/r/agent/inbox")
        XCTAssertEqual(paths.inbox, AppPaths(root: URL(fileURLWithPath: "/r")).agentInbox)
        XCTAssertNil(paths.responseFile(requestId: "x"), "too short to be a request id")
    }

    func testEnvironmentOverridesRoot() {
        let paths = AgentHookPaths.resolve(environment: [
            AgentHookPaths.rootVariable: "/tmp/root", AgentHookPaths.controlVariable: "/tmp/control",
        ])
        XCTAssertEqual(paths.root.path, "/tmp/root")
        XCTAssertEqual(paths.controlDir.path, "/tmp/control")
        XCTAssertEqual(AgentHookPaths.resolve(environment: [:]).root, AppPaths.defaultRoot)
    }

    func testGitBranchFromHeadAndWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature/voice\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentHookGit.branch(at: nested.path), "feature/voice")

        let worktree = root.appendingPathComponent("wt")
        let gitDir = repo.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "0123456789abcdef\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentHookGit.branch(at: worktree.path), "0123456")

        XCTAssertNil(AgentHookGit.branch(at: root.path))
    }
}
