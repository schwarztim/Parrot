import XCTest
@testable import Parrot

/// Builds the real `parrot-agent-hook` from `AgentHook/` with swiftc, runs
/// it on documented hook payloads with every path pointed at a temp folder,
/// plays Parrot's side through the inbox and response files, and checks the
/// JSON the helper prints, its exit code, and the files it leaves.
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
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // Parrot sets the agent folder up; the helper refuses to create it.
        XCTAssertEqual(AgentHookPaths.secureDirectory(paths.agentDir, create: true), .secure)
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

    /// A request as Parrot sees it: from an inbox file, or from a link.
    private struct Request {
        var requestId: String
        var message: AgentInboxMessage?
        /// Mode of the inbox file when it was read.
        var fileMode: Int?
    }

    private struct HookRun {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var seconds: TimeInterval
        var request: Request?
        var message: AgentInboxMessage? { request?.message }
    }

    /// Runs the helper with `stdin`. When `answer` is given, waits for the
    /// request (an inbox update unless `readRequest` says otherwise), then
    /// writes the returned response where Parrot does:
    /// `responses/<requestId>.json`, 0600.
    private func run(
        _ arguments: [String],
        stdin: String,
        timeout: Int = 15,
        answer: ((Request) -> AgentHookResponse?)? = nil,
        readRequest: (() throws -> Request?)? = nil
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

        var request: Request?
        if let answer {
            request = try waitFor(seconds: 10) { try (readRequest ?? self.inboxRequest)() }
            if let request, let response = answer(request) {
                let file = try XCTUnwrap(paths.responseFile(requestId: request.requestId))
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
            request: request
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

    private func inboxFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: paths.inbox.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func inboxMessages() throws -> [AgentInboxMessage] {
        try inboxFiles().map { try JSONDecoder().decode(AgentInboxMessage.self, from: Data(contentsOf: $0)) }
    }

    private func inboxRequest() throws -> Request? {
        for file in try inboxFiles() {
            guard let message = try? JSONDecoder().decode(AgentInboxMessage.self, from: Data(contentsOf: file)),
                  message.kind == .update
            else { continue }
            return Request(requestId: message.requestId, message: message, fileMode: try mode(file))
        }
        return nil
    }

    private func writeState(enabled: Bool, pid: Int32) throws {
        let state = AgentHookState(enabled: enabled, appPid: pid, responseTimeout: 30)
        try AgentHookPaths.writeAtomically(try JSONEncoder().encode(state), to: paths.stateFile)
    }

    private func object(_ text: String) throws -> HookJSON {
        try JSONDecoder().decode(HookJSON.self, from: Data(text.utf8))
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: - Round Trips

    func testClaudeStopReplyContinuesTheAgent() throws {
        let project = temp.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: project.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let stdin = HookPayloadTests.claudeStop.replacingOccurrences(of: "/Users/example/my-project", with: project.path)

        let result = try run(["claude"], stdin: stdin) { request in
            AgentHookResponse(requestId: request.requestId, action: .reply, text: "Run the tests again")
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
        XCTAssertTrue(AgentInboxMessage.isValidRequestId(message.requestId))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try object(result.stdout), try object(#"{"decision":"block","reason":"Run the tests again"}"#))
        XCTAssertEqual(contents(paths.responses), [], "the helper removes the response file")
        XCTAssertEqual(contents(paths.inbox), [], "and its own inbox file")
    }

    func testClaudePermissionAlwaysAllowEchoesSuggestion() throws {
        let result = try run(["claude"], stdin: HookPayloadTests.claudePermission) { request in
            AgentHookResponse(requestId: request.requestId, action: .allowAlways, suggestionIndex: 0)
        }
        XCTAssertEqual(result.message?.permission?.details, "rm -rf node_modules")
        XCTAssertEqual(result.exitCode, 0)
        let decision = try object(result.stdout)["hookSpecificOutput"]?["decision"]
        XCTAssertEqual(decision?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(decision?["updatedPermissions"]?.arrayValue?.first?["destination"]?.stringValue, "localSettings")
    }

    func testCodexPermissionDenyAndStopReply() throws {
        let deny = try run(["codex"], stdin: HookPayloadTests.codexPermission) { request in
            AgentHookResponse(requestId: request.requestId, action: .deny, text: "Not on main")
        }
        XCTAssertEqual(deny.message?.agent, .codex)
        XCTAssertEqual(deny.exitCode, 0)
        XCTAssertEqual(
            try object(deny.stdout),
            try object(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Not on main"}}}"#)
        )

        let stop = try run(["codex"], stdin: HookPayloadTests.codexStop) { request in
            AgentHookResponse(requestId: request.requestId, action: .reply, text: "Ship it")
        }
        XCTAssertEqual(stop.exitCode, 0)
        XCTAssertEqual(try object(stop.stdout), try object(#"{"decision":"block","reason":"Ship it"}"#))
    }

    func testClaudeQuestionAnswersAndPlanFeedback() throws {
        let question = try run(["claude"], stdin: HookPayloadTests.claudeQuestion) { request in
            AgentHookResponse(requestId: request.requestId, action: .answer, answers: ["Which framework?": ["Vue"], "Which extras?": ["State"]])
        }
        XCTAssertEqual(question.message?.questions?.count, 2)
        let updated = try object(question.stdout)["hookSpecificOutput"]?["updatedInput"]
        XCTAssertEqual(updated?["answers"]?["Which framework?"]?.stringValue, "Vue")
        XCTAssertEqual(updated?["questions"]?.arrayValue?.count, 2)

        let plan = try run(["claude"], stdin: HookPayloadTests.claudePlan) { request in
            AgentHookResponse(requestId: request.requestId, action: .rejectPlan, text: "Smaller steps")
        }
        XCTAssertEqual(plan.message?.event, .plan)
        let specific = try object(plan.stdout)["hookSpecificOutput"]
        XCTAssertEqual(specific?["permissionDecision"]?.stringValue, "deny")
        XCTAssertEqual(specific?["permissionDecisionReason"]?.stringValue, "Smaller steps")
    }

    func testDismissPrintsNothing() throws {
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop) { request in
            AgentHookResponse(requestId: request.requestId, action: .dismiss)
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
    }

    // MARK: - Private Files

    func testFoldersAre0700AndFilesAre0600() throws {
        // A loose agent folder (as an older Parrot or a user may leave it)
        // is tightened before use.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.agentDir.path)
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop) { request in
            AgentHookResponse(requestId: request.requestId, action: .reply, text: "ok")
        }
        XCTAssertEqual(result.request?.fileMode, 0o600, "inbox file")
        XCTAssertEqual(try mode(paths.agentDir), 0o700)
        XCTAssertEqual(try mode(paths.inbox), 0o700)
        XCTAssertEqual(try mode(paths.responses), 0o700)
        XCTAssertEqual(try object(result.stdout)["reason"]?.stringValue, "ok")
    }

    func testLongMessageGoesToAPrivateFileThatIsCleanedUp() throws {
        let long = String(repeating: "x", count: AgentInboxMessage.inlineLimit + 10)
        let stdin = HookPayloadTests.claudeStop.replacingOccurrences(
            of: "I've completed the refactoring.\\nHere's a summary...", with: long
        )
        var fileMode: Int?
        let result = try run(["claude"], stdin: stdin) { request in
            if let file = self.paths.messageFile(requestId: request.requestId) {
                fileMode = try? self.mode(file)
            }
            return AgentHookResponse(requestId: request.requestId, action: .dismiss)
        }
        XCTAssertEqual(result.message?.messageInFile, true)
        XCTAssertEqual(result.message?.message?.count, AgentInboxMessage.inlineLimit)
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(try mode(paths.messages), 0o700)
        XCTAssertEqual(contents(paths.messages), [], "deleted when the helper exits")
    }

    func testSymlinkedAgentFolderIsRefused() throws {
        // The agent folder swapped for a link to somewhere else: exit at once
        // and write nothing there.
        let elsewhere = temp.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: paths.agentDir, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: paths.agentDir, withDestinationURL: elsewhere)
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 5)
        XCTAssertEqual(contents(elsewhere), ["state.json"])
    }

    func testSymlinkedControlFolderIsRefused() throws {
        let real = temp.appendingPathComponent("real-control")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: real.appendingPathComponent("bypass-abc123").path, contents: Data())
        try FileManager.default.createSymbolicLink(at: paths.controlDir, withDestinationURL: real)
        let result = try run(["claude"], stdin: HookPayloadTests.claudePermission)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "", "a planted bypass marker behind a link is never honored")
        XCTAssertEqual(try inboxMessages().count, 0)
    }

    // MARK: - Never Block the CLI

    func testTimeoutExitsSilentlyAndCleansUp() throws {
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop, timeout: 1)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 6)
        // Its unread update is gone; only the dismiss for Parrot remains.
        let messages = try inboxMessages()
        XCTAssertEqual(messages.map(\.kind), [.dismiss])
        XCTAssertTrue(AgentInboxMessage.isValidRequestId(messages.first?.requestId ?? ""))
        XCTAssertEqual(contents(paths.responses), [])
    }

    func testDisabledSessionExitsAtOnce() throws {
        XCTAssertEqual(AgentHookPaths.secureDirectory(paths.controlDir, create: true), .secure)
        FileManager.default.createFile(atPath: paths.disabledMarker(sessionId: "abc123").path, contents: Data())
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertLessThan(result.seconds, 5)
        XCTAssertEqual(try inboxMessages().count, 0)
    }

    func testBypassMarkerAllowsWithoutAsking() throws {
        XCTAssertEqual(AgentHookPaths.secureDirectory(paths.controlDir, create: true), .secure)
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

    func testMissingAgentFolderExitsAtOnce() throws {
        try FileManager.default.removeItem(at: paths.agentDir)
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop)
        XCTAssertEqual(result.stdout, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.agentDir.path), "the helper never creates it")
    }

    func testInboxFailureFallsBackToAMinimalDeepLink() throws {
        // An inbox folder the user cannot write makes the write fail.
        XCTAssertEqual(AgentHookPaths.secureDirectory(paths.inbox, create: true), .secure)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.inbox.path) }

        var link: URL?
        let result = try run(["claude"], stdin: HookPayloadTests.claudeStop, answer: { request in
            AgentHookResponse(requestId: request.requestId, action: .reply, text: "From the link")
        }, readRequest: {
            guard let text = try? String(contentsOf: self.openerLog, encoding: .utf8), let url = URL(string: text),
                  let parsed = AgentDeepLink(url: url)
            else { return nil }
            link = url
            return Request(requestId: parsed.requestId, message: nil, fileMode: nil)
        })
        XCTAssertEqual(try object(result.stdout), try object(#"{"decision":"block","reason":"From the link"}"#))

        let url = try XCTUnwrap(link)
        XCTAssertEqual(url.host(), "agent-update")
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).sorted()
        XCTAssertEqual(names, ["agent", "event", "project", "request"])
        XCTAssertFalse(url.absoluteString.contains("refactoring"), "no agent message in the link")
        XCTAssertFalse(url.absoluteString.contains("abc123"), "no session id in the link")
    }

    func testEnablePhraseClearsTheDisabledMarker() throws {
        XCTAssertEqual(AgentHookPaths.secureDirectory(paths.controlDir, create: true), .secure)
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
        let messages = try inboxMessages()
        XCTAssertEqual(messages.map(\.kind), [.dismiss])
        XCTAssertEqual(messages.first?.requestId, "")
        XCTAssertEqual(try mode(try XCTUnwrap(try inboxFiles().first)), 0o600)
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
