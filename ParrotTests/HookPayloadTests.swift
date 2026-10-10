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
            responseFile: "/tmp/r1.json", hookPid: 42, branch: "main"
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
            responseFile: "/tmp/r2.json", hookPid: 1, branch: nil
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
            responseFile: "/tmp/r3.json", hookPid: 1, branch: nil
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
            responseFile: "/tmp/r4.json", hookPid: 1, branch: nil
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

        let bypass = HookDecision.permissionUpdate(input: input, response: AgentHookResponse(requestId: "r", action: .bypass))
        XCTAssertEqual(bypass?.compactText, #"{"destination":"session","mode":"bypassPermissions","type":"setMode"}"#)

        // No suggestions (file edit dialogs send none): a whole-tool rule.
        var edit = input
        edit.toolName = "Edit"
        edit.permissionSuggestions = nil
        let always = HookDecision.permissionUpdate(input: edit, response: AgentHookResponse(requestId: "r", action: .allowAlways))
        XCTAssertEqual(always?.compactText, #"{"behavior":"allow","destination":"localSettings","rules":[{"toolName":"Edit"}],"type":"addRules"}"#)
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

    func testDeepLinkCarriesTheMessage() throws {
        let input = try decode(Self.claudePermission)
        let message = AgentInboxMessage.update(
            agent: .claude, event: .permission, input: input, requestId: "r5",
            responseFile: "/tmp/r5.json", hookPid: 7, branch: "main"
        )
        let url = try XCTUnwrap(message.deepLink)
        XCTAssertEqual(url.scheme, "parrot")
        XCTAssertEqual(url.host(), "agent-update")
        XCTAssertEqual(URLRoute(url), .agent(url))
        XCTAssertEqual(AgentInboxMessage(deepLink: url), message)

        let dismiss = AgentInboxMessage.dismiss(agent: .codex, sessionId: "s", requestId: "r6", hookPid: nil)
        XCTAssertEqual(dismiss.deepLink?.host(), "agent-dismiss")
        XCTAssertNil(AgentInboxMessage(deepLink: URL(string: "parrot://agent-update?payload=%%%")!))
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
        XCTAssertEqual(paths.responseFile(requestId: "x").path, "/r/agent/responses/x.json")
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
