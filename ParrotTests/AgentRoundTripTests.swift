import XCTest
@testable import Parrot

/// Builds the real `parrot-agent-hook` from `AgentHook/` with swiftc, runs
/// it on documented hook payloads with every path pointed at a temp folder,
/// plays Parrot's side through the inbox and response files, and checks the
/// JSON the helper prints and its exit code.
///
/// Never touches `~/.claude`, `~/.codex` or Parrot's real Application
/// Support folder, and the deep link opener is a stub script.
final class AgentRoundTripTests: XCTestCase {

    private var temp: URL!
    private var paths: AgentHookPaths!
    private var openerLog: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-roundtrip-\(UUID().uuidString)")
        paths = AgentHookPaths(root: temp.appendingPathComponent("root"), controlDir: temp.appendingPathComponent("control"))
        try FileManager.default.createDirectory(at: paths.agentDir, withIntermediateDirectories: true)
        openerLog = temp.appendingPathComponent("opened.txt")
        try writeState(enabled: true, pid: getpid())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Building the Helper

    private static var builtHelper: Result<URL, Error>?

    private struct BuildFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Compiles `AgentHook/*.swift` once per test run.
    private static func helper() throws -> URL {
        if let builtHelper { return try builtHelper.get() }
        let result = Result { try compileHelper() }
        builtHelper = result
        return try result.get()
    }

    private static func compileHelper() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repo.appendingPathComponent("AgentHook")
        let sources = try FileManager.default.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map(\.path)
            .sorted()
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-agent-hook-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let binary = outDir.appendingPathComponent("parrot-agent-hook")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "swiftc", "-swift-version", "5", "-module-name", "parrot_agent_hook", "-o", binary.path] + sources
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let log = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildFailure(description: "swiftc failed: " + String(decoding: log, as: UTF8.self))
        }
        return binary
    }

    // MARK: - Running the Helper

    private struct HookRun {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var seconds: TimeInterval
        var message: AgentInboxMessage?
    }

    /// Runs the helper with `stdin`. When `answer` is given, waits for the
    /// inbox update, then writes the returned response like Parrot does.
    private func run(
        _ arguments: [String],
        stdin: String,
        timeout: Int = 15,
        answer: ((AgentInboxMessage) -> AgentHookResponse?)? = nil,
        readUpdate: (() throws -> AgentInboxMessage?)? = nil
    ) throws -> HookRun {
        let process = Process()
        process.executableURL = try Self.helper()
        process.arguments = arguments
        process.environment = [
            "HOME": temp.path,
            "PATH": "/usr/bin:/bin",
            AgentHookPaths.rootVariable: paths.root.path,
            AgentHookPaths.controlVariable: paths.controlDir.path,
            AgentHookPaths.timeoutVariable: String(timeout),
            AgentHookPaths.openerVariable: try openerScript().path,
        ]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()

        var message: AgentInboxMessage?
        if let answer {
            message = try waitFor(seconds: 10) { try (readUpdate ?? self.inboxUpdate)() }
            if let message, let response = answer(message) {
                let file = URL(fileURLWithPath: try XCTUnwrap(message.responseFile))
                try AgentHookPaths.writeAtomically(try JSONEncoder().encode(response), to: file)
            }
        }

        let deadline = Date().addingTimeInterval(Double(timeout) + 10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("helper did not exit")
        }
        process.waitUntilExit()
        return HookRun(
            exitCode: process.terminationStatus,
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            seconds: Date().timeIntervalSince(started),
            message: message
        )
    }

    private func openerScript() throws -> URL {
        let script = temp.appendingPathComponent("opener.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try "#!/bin/sh\nprintf '%s' \"$1\" > '\(openerLog.path)'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return script
    }

    private func waitFor<T>(seconds: TimeInterval, _ probe: () throws -> T?) throws -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = try probe() { return value }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func inboxMessages() throws -> [AgentInboxMessage] {
        guard FileManager.default.fileExists(atPath: paths.inbox.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(AgentInboxMessage.self, from: Data(contentsOf: $0)) }
    }

    private func inboxUpdate() throws -> AgentInboxMessage? {
        try inboxMessages().first { $0.kind == .update }
    }

    private func writeState(enabled: Bool, pid: Int32) throws {
        let state = AgentHookState(enabled: enabled, appPid: pid, responseTimeout: 30)
        try AgentHookPaths.writeAtomically(try JSONEncoder().encode(state), to: paths.stateFile)
    }

    private func object(_ text: String) throws -> HookJSON {
        try JSONDecoder().decode(HookJSON.self, from: Data(text.utf8))
    }

    // MARK: - Round Trips

    func testClaudeStopReplyContinuesTheAgent() throws {
        let project = temp.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: project.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let stdin = HookPayloadTests.claudeStop.replacingOccurrences(of: "/Users/example/my-project", with: project.path)

        let result = try run(["claude"], stdin: stdin) { message in
            AgentHookResponse(requestId: message.requestId, action: .reply, text: "Run the tests again")
        }

        let message = try XCTUnwrap(result.message)
        XCTAssertEqual(message.kind, .update)
        XCTAssertEqual(message.agent, .claude)
        XCTAssertEqual(message.event, .stop)
        XCTAssertEqual(message.sessionId, "abc123")
        XCTAssertEqual(message.project, "my-project")
        XCTAssertEqual(message.branch, "main")
        XCTAssertEqual(message.message, "I've completed the refactoring.\nHere's a summary...")
        XCTAssertGreaterThan(message.hookPid ?? 0, 0)
        XCTAssertTrue(message.responseFile?.hasPrefix(paths.responses.path) ?? false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try object(result.stdout), try object(#"{"decision":"block","reason":"Run the tests again"}"#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: message.responseFile ?? "/"), "the helper removes the response file")
    }

    func testClaudePermissionAlwaysAllowEchoesSuggestion() throws {
        let result = try run(["claude"], stdin: HookPayloadTests.claudePermission) { message in
            XCTAssertEqual(message.permission?.details, "rm -rf node_modules")
            return AgentHookResponse(requestId: message.requestId, action: .allowAlways, suggestionIndex: 0)
        }
        XCTAssertEqual(result.exitCode, 0)
        let decision = try object(result.stdout)["hookSpecificOutput"]?["decision"]
        XCTAssertEqual(decision?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(decision?["updatedPermissions"]?.arrayValue?.first?["destination"]?.stringValue, "localSettings")
    }

    func testCodexPermissionDenyAndStopReply() throws {
        let deny = try run(["codex"], stdin: HookPayloadTests.codexPermission) { message in
            AgentHookResponse(requestId: message.requestId, action: .deny, text: "Not on main")
        }
        XCTAssertEqual(deny.message?.agent, .codex)
        XCTAssertEqual(deny.exitCode, 0)
        XCTAssertEqual(
            try object(deny.stdout),
            try object(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Not on main"}}}"#)
        )

        try FileManager.default.removeItem(at: paths.inbox)
        let stop = try run(["codex"], stdin: HookPayloadTests.codexStop) { message in
            AgentHookResponse(requestId: message.requestId, action: .reply, text: "Ship it")
        }
        XCTAssertEqual(stop.exitCode, 0)
        XCTAssertEqual(try object(stop.stdout), try object(#"{"decision":"block","reason":"Ship it"}"#))
    }

    func testClaudeQuestionAnswersAndPlanFeedback() throws {
        let question = try run(["claude"], stdin: HookPayloadTests.claudeQuestion) { message in
            XCTAssertEqual(message.questions?.count, 2)
            return AgentHookResponse(requestId: message.requestId, action: .answer, answers: ["Which framework?": ["Vue"], "Which extras?": ["State"]])
        }
        let updated = try object(question.stdout)["hookSpecificOutput"]?["updatedInput"]
        XCTAssertEqual(updated?["answers"]?["Which framework?"]?.stringValue, "Vue")
        XCTAssertEqual(updated?["questions"]?.arrayValue?.count, 2)

        try FileManager.default.removeItem(at: paths.inbox)
        let plan = try run(["claude"], stdin: HookPayloadTests.claudePlan) { message in
            XCTAssertEqual(message.event, .plan)
            return AgentHookResponse(requestId: message.requestId, action: .rejectPlan, text: "Smaller steps")
        }
        let specific = try object(plan.stdout)["hookSpecificOutput"]
        XCTAssertEqual(specific?["permissionDecision"]?.stringValue, "deny")
        XCTAssertEqual(specific?["permissionDecisionReason"]?.stringValue, "Smaller steps")
    }

    func testDismissPrintsNothing() throws {
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop) { message in
            AgentHookResponse(requestId: message.requestId, action: .dismiss)
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
    }

    // MARK: - Never Block the CLI

    func testTimeoutExitsSilentlyAndDismisses() throws {
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop, timeout: 1)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 6)
        let messages = try inboxMessages()
        XCTAssertEqual(messages.map(\.kind), [.update, .dismiss])
        XCTAssertEqual(messages.last?.requestId, messages.first?.requestId)
    }

    func testDisabledSessionExitsAtOnce() throws {
        try FileManager.default.createDirectory(at: paths.controlDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.disabledMarker(sessionId: "abc123").path, contents: Data())
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 5)
        XCTAssertEqual(try inboxMessages().count, 0)
    }

    func testBypassMarkerAllowsWithoutAsking() throws {
        try FileManager.default.createDirectory(at: paths.controlDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.bypassMarker(sessionId: "abc123").path, contents: Data())
        let result = try run(["claude"], stdin: HookPayloadTests.claudePermission)
        XCTAssertEqual(try object(result.stdout)["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(try inboxMessages().count, 0)
    }

    func testAppNotListeningExitsAtOnce() throws {
        try writeState(enabled: false, pid: getpid())
        var result = try run(["claude"], stdin: HookPayloadTests.claudeStop)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 5)

        // A pid that has exited: Parrot is not running.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try writeState(enabled: true, pid: gone.processIdentifier)
        result = try run(["codex"], stdin: HookPayloadTests.codexStop)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 5)
        XCTAssertEqual(try inboxMessages().count, 0)
    }

    func testInboxFailureFallsBackToDeepLink() throws {
        // A plain file where the inbox folder should be makes the write fail.
        try FileManager.default.createDirectory(at: paths.agentDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.inbox.path, contents: Data("x".utf8))

        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop, answer: { message in
            AgentHookResponse(requestId: message.requestId, action: .reply, text: "From the link")
        }, readUpdate: {
            guard let text = try? String(contentsOf: self.openerLog, encoding: .utf8), let url = URL(string: text) else { return nil }
            XCTAssertEqual(url.host(), "agent-update")
            return AgentInboxMessage(deepLink: url)
        })
        XCTAssertEqual(result.message?.sessionId, "abc123")
        XCTAssertEqual(try object(result.stdout), try object(#"{"decision":"block","reason":"From the link"}"#))
    }

    func testEnablePhraseClearsTheDisabledMarker() throws {
        try FileManager.default.createDirectory(at: paths.controlDir, withIntermediateDirectories: true)
        let marker = paths.disabledMarker(sessionId: "abc123")
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        let prompt = #"{"session_id":"abc123","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"enable parrot"}"#
        let result = try run(["claude"], stdin: prompt)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try object(result.stdout)["decision"]?.stringValue, "block")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // Any other prompt takes the session's card down.
        let other = #"{"session_id":"abc123","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"keep going"}"#
        let typed = try run(["codex"], stdin: other)
        XCTAssertEqual(typed.stdout, "")
        XCTAssertEqual(try inboxMessages().map(\.kind), [.dismiss])
    }

    func testBadArgumentsAndInputExitZero() throws {
        let usage = try run([], stdin: "{}")
        XCTAssertEqual(usage.exitCode, 0)
        XCTAssertEqual(usage.stdout, "")
        XCTAssertTrue(usage.stderr.contains("usage: parrot-agent-hook"))

        let garbage = try run(["claude"], stdin: "not json")
        XCTAssertEqual(garbage.exitCode, 0)
        XCTAssertEqual(garbage.stdout, "")
    }
}
