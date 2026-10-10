import XCTest
@testable import Parrot

/// Panel stand-in: records show and hide calls, opens no window.
@MainActor
final class FakeAgentPanel: AgentPanelPresenting {
    var isVisible = false
    var shows: [Bool] = []
    var hides = 0

    func show(activate: Bool) {
        isVisible = true
        shows.append(activate)
    }

    func hide(restoreFocus: Bool) {
        isVisible = false
        hides += 1
    }
}

/// A bridge on temp folders and throwaway settings, with fake process
/// checks, clipboard, toasts and panel. Never touches real Parrot data.
///
/// Request ids in these tests look like `request-a1` (valid ids are 8 to
/// 64 letters, digits and dashes).
@MainActor
final class AgentFixture {
    let temp: URL
    let suite: String
    let settings: AppSettings
    let bridge = AgentBridge()
    let panel = FakeAgentPanel()
    var copied: [String] = []
    var toasts: [String] = []
    var alive: Set<Int32> = [100, 101, 102, 103]

    init(enabled: Bool = true, root: URL? = nil) {
        temp = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("agent-queue-\(UUID().uuidString)")
        suite = "parrot.tests.agent.\(UUID().uuidString)"
        settings = AppSettings(store: SettingsStore(defaults: UserDefaults(suiteName: suite)!), secrets: InMemorySecretStore())
        settings.agent.enabled = enabled
        bridge.isProcessAlive = { [unowned self] pid in self.alive.contains(pid) }
        bridge.panel = panel
        bridge.configure(root: temp.appendingPathComponent("root"), controlDir: temp.appendingPathComponent("control"), settings: settings.agent)
        bridge.delivery?.copyToClipboard = { [unowned self] text in self.copied.append(text) }
        bridge.delivery?.notify = { [unowned self] text in self.toasts.append(text) }
        bridge.delivery?.sleep = { _ in }
    }

    var paths: AgentHookPaths { AgentHookPaths(root: temp.appendingPathComponent("root"), controlDir: temp.appendingPathComponent("control")) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: temp)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func update(
        _ event: HookEvent, session: String, request: String, pid: Int32 = 100,
        agent: HookAgent = .claude, message: String = "Done."
    ) -> AgentInboxMessage {
        var update = AgentInboxMessage(
            kind: .update, agent: agent, sessionId: session, requestId: request, event: event,
            summary: AgentInboxMessage.firstLine(of: message), message: message,
            cwd: "/Users/example/app", project: "app", branch: "main", hookPid: pid,
            createdAt: Date().timeIntervalSince1970
        )
        if event == .permission {
            update.permission = HookPermission(agent: agent, toolName: "Bash", toolInput: .object(["command": .string("make")]), suggestions: nil)
        }
        if event == .question {
            update.questions = [
                HookQuestion(question: "Which framework?", options: [.init(label: "React"), .init(label: "Vue")]),
                HookQuestion(question: "Which extras?", options: [.init(label: "Router"), .init(label: "State")], multiSelect: true),
            ]
        }
        return update
    }

    func link(_ event: HookEvent, request: String, agent: HookAgent = .claude) -> URL {
        AgentDeepLink(kind: .update, requestId: request, agent: agent, event: event, project: "app").url!
    }

    /// Drops `message` into the inbox the way the helper does.
    func drop(_ message: AgentInboxMessage, order: Int) throws {
        let name = String(format: "%013d-%@-%@.json", order, message.requestId, message.kind.rawValue)
        try AgentHookPaths.writeAtomically(try JSONEncoder().encode(message), to: paths.inbox.appendingPathComponent(name))
    }

    func response(for request: String) throws -> AgentHookResponse? {
        guard let file = paths.responseFile(requestId: request), let data = try? Data(contentsOf: file) else { return nil }
        return try JSONDecoder().decode(AgentHookResponse.self, from: data)
    }

    /// Every file under the temp folder, relative paths, sorted.
    func allFiles() -> [String] {
        let base = temp.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(atPath: base)
        var files: [String] = []
        while let item = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + "/" + item, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(item)
            }
        }
        return files.sorted()
    }

    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Lets queued main-actor tasks run.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
final class SessionQueueTests: XCTestCase {

    private func makeFixture(enabled: Bool = true) -> AgentFixture {
        let fixture = AgentFixture(enabled: enabled)
        addTeardownBlock { @MainActor in fixture.cleanUp() }
        return fixture
    }

    // MARK: - Store

    func testQueueKeepsArrivalOrderAndReplacesInPlace() {
        let store = AgentSessionStore()
        let fixture = makeFixture()
        XCTAssertEqual(store.apply(fixture.update(.stop, session: "a", request: "request-a1")), .shown)
        XCTAssertEqual(store.apply(fixture.update(.permission, session: "b", request: "request-b1")), .queued)
        XCTAssertEqual(store.apply(fixture.update(.stop, session: "c", request: "request-c1")), .queued)
        XCTAssertEqual(store.current?.sessionId, "a")
        XCTAssertEqual(store.queued.map(\.sessionId), ["b", "c"])
        XCTAssertEqual(store.queued.first?.status, .permissionNeeded)

        // A newer request for b replaces it where it stands.
        XCTAssertEqual(store.apply(fixture.update(.question, session: "b", request: "request-b2")), .replaced)
        XCTAssertEqual(store.sessions.map(\.requestId), ["request-a1", "request-b2", "request-c1"])
        XCTAssertEqual(store.sessions[1].status, .question)

        // An invalid request id is never queued.
        XCTAssertEqual(store.apply(fixture.update(.stop, session: "d", request: "../../x")), .ignored)
    }

    func testDismissMatchesRequestOrWholeSession() {
        let store = AgentSessionStore()
        let fixture = makeFixture()
        store.apply(fixture.update(.stop, session: "a", request: "request-a2"))
        store.apply(fixture.update(.stop, session: "b", request: "request-b1"))

        // A late dismiss for an older request leaves the newer one alone.
        XCTAssertEqual(store.apply(.dismiss(agent: .claude, sessionId: "a", requestId: "request-a1", hookPid: nil)), .ignored)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.apply(.dismiss(agent: .claude, sessionId: "a", requestId: "request-a2", hookPid: nil)), .removed)
        // An empty request id (the user typed in the terminal) clears the session.
        XCTAssertEqual(store.apply(.dismiss(agent: .claude, sessionId: "b", requestId: "", hookPid: nil)), .removed)
        XCTAssertNil(store.current)
    }

    func testPersistsAcrossRelaunchAndDropsDeadHelpers() throws {
        let fixture = makeFixture()
        let file = fixture.temp.appendingPathComponent("sessions.json")
        let store = AgentSessionStore(fileURL: file)
        store.apply(fixture.update(.stop, session: "a", request: "request-a1", pid: 100))
        store.apply(fixture.update(.permission, session: "b", request: "request-b1", pid: 200))
        store.setBypassed(true, sessionId: "b")
        store.setStatus(.sending, requestId: "request-a1")
        XCTAssertEqual(try fixture.mode(file), 0o600)

        let relaunched = AgentSessionStore(fileURL: file)
        relaunched.load { $0 == 100 }
        XCTAssertEqual(relaunched.sessions.map(\.requestId), ["request-a1"])
        XCTAssertEqual(relaunched.current?.status, .completed, "a send cut off by quitting is shown again")
        XCTAssertEqual(relaunched.current?.message, "Done.")
        XCTAssertEqual(relaunched.bypassed, ["b"])
    }

    func testPruneDropsDeadHelpersAndExpiresLinkRequests() throws {
        let store = AgentSessionStore()
        let fixture = makeFixture()
        store.apply(fixture.update(.stop, session: "a", request: "request-a1", pid: 100))
        store.apply(fixture.update(.stop, session: "b", request: "request-b1", pid: 101))
        let dead = store.pruneDeadProcesses(isAlive: { $0 == 101 })
        XCTAssertEqual(dead.map(\.sessionId), ["a"])
        XCTAssertEqual(store.current?.sessionId, "b")

        let link = try XCTUnwrap(AgentDeepLink(url: fixture.link(.stop, request: "request-l1")))
        store.apply(link: link)
        XCTAssertEqual(store.pruneDeadProcesses(isAlive: { _ in true }, now: Date().addingTimeInterval(60), maxAge: 300), [])
        let expired = store.pruneDeadProcesses(isAlive: { _ in true }, now: Date().addingTimeInterval(301), maxAge: 300)
        XCTAssertEqual(expired.map(\.requestId), ["request-l1"])
    }

    // MARK: - Bridge

    func testInboxShowsPanelWithoutTakingFocus() throws {
        let fixture = makeFixture()
        try fixture.drop(fixture.update(.stop, session: "a", request: "request-a1", message: "All **done**.\nTests pass."), order: 1)
        try fixture.drop(fixture.update(.stop, session: "b", request: "request-b1"), order: 2)
        fixture.bridge.scanInbox()

        XCTAssertEqual(fixture.bridge.currentSession?.sessionId, "a")
        XCTAssertEqual(fixture.bridge.currentSession?.summary, "All **done**.")
        XCTAssertEqual(fixture.bridge.currentSession?.trusted, true)
        XCTAssertEqual(fixture.bridge.waitingCount, 2)
        XCTAssertEqual(fixture.panel.shows, [false], "agent updates never steal focus")
        XCTAssertTrue(fixture.bridge.isAcceptingDictation)
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.inbox.path)
        XCTAssertEqual(left, [], "processed inbox files are deleted")
    }

    func testSymlinkInInboxIsRemovedUnread() throws {
        let fixture = makeFixture()
        let outside = fixture.temp.appendingPathComponent("outside.json")
        try JSONEncoder().encode(fixture.update(.stop, session: "a", request: "request-a1")).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.paths.inbox.appendingPathComponent("1-x-update.json"), withDestinationURL: outside)
        fixture.bridge.scanInbox()
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.inbox.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "the link target is left alone")
    }

    func testReplyWritesResponseAndPromotesNext() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1"))
        fixture.bridge.ingest(fixture.update(.stop, session: "b", request: "request-b1"))
        await fixture.bridge.receiveDictation("Run the linter")
        await fixture.bridge.receiveDictation("then commit")
        XCTAssertEqual(fixture.bridge.draft, "Run the linter then commit")

        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "request-a1"), AgentHookResponse(requestId: "request-a1", action: .reply, text: "Run the linter then commit"))
        XCTAssertEqual(fixture.bridge.currentSession?.sessionId, "b")
        XCTAssertEqual(fixture.bridge.draft, "", "the editor clears for the next session")

        await fixture.bridge.dismissCurrent()
        XCTAssertEqual(try fixture.response(for: "request-b1")?.action, .dismiss)
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertGreaterThan(fixture.panel.hides, 0)
    }

    func testAgentFilesAndFoldersArePrivate() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "request-a1"))
        await fixture.bridge.respond(.bypass)
        let paths = fixture.paths
        for folder in [paths.agentDir, paths.inbox, paths.responses, paths.messages, paths.controlDir] {
            XCTAssertEqual(try fixture.mode(folder), 0o700, folder.lastPathComponent)
        }
        let files = [
            try XCTUnwrap(paths.responseFile(requestId: "request-a1")), paths.stateFile,
            paths.agentDir.appendingPathComponent("sessions.json"), paths.bypassMarker(sessionId: "a"),
        ]
        for file in files {
            XCTAssertEqual(try fixture.mode(file), 0o600, file.lastPathComponent)
        }
    }

    func testSymlinkedAgentFolderTurnsTheBridgeOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-link-\(UUID().uuidString)")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("root"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("root/agent"), withDestinationURL: elsewhere)
        let fixture = AgentFixture(root: root)
        addTeardownBlock { @MainActor in fixture.cleanUp() }

        XCTAssertNil(fixture.bridge.hookPaths)
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1"))
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing written through the link")
    }

    func testShiftHeldAutoSendsTheReply() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1"))
        await fixture.bridge.receiveDictation("Ship it", autoSend: true)
        XCTAssertEqual(try fixture.response(for: "request-a1")?.text, "Ship it")
    }

    func testDeadHelperSendsReplyToClipboard() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1", pid: 100))
        fixture.alive = []
        fixture.bridge.draft = "Keep this text"
        await fixture.bridge.sendDraft()
        XCTAssertNil(try fixture.response(for: "request-a1"))
        XCTAssertEqual(fixture.copied, ["Keep this text"])
        XCTAssertEqual(fixture.toasts, ["Couldn't reach Claude Code. Your reply is on the clipboard."])
    }

    func testTickDropsSessionsWhoseHelperExited() {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1", pid: 100))
        fixture.bridge.ingest(fixture.update(.stop, session: "b", request: "request-b1", pid: 101))
        fixture.alive = [101]
        fixture.bridge.tick()
        XCTAssertEqual(fixture.bridge.currentSession?.sessionId, "b")
        fixture.alive = []
        fixture.bridge.tick()
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testSweepRemovesOrphanResponses() throws {
        let fixture = makeFixture()
        let old = try XCTUnwrap(fixture.paths.responseFile(requestId: "request-old1"))
        let fresh = try XCTUnwrap(fixture.paths.responseFile(requestId: "request-new1"))
        try AgentHookPaths.writeAtomically(Data("{}".utf8), to: old)
        try AgentHookPaths.writeAtomically(Data("{}".utf8), to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        fixture.bridge.sweepOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testDeliveryRetriesThenFallsBack() async throws {
        let fixture = makeFixture()
        let queue = try XCTUnwrap(fixture.bridge.delivery)
        var calls = 0
        queue.writer = { _, _ in
            calls += 1
            if calls < 3 { throw CocoaError(.fileWriteNoPermission) }
        }
        let target = fixture.paths.responseFile(requestId: "request-r1")
        let ok = await queue.send(AgentHookResponse(requestId: "request-r1", action: .allow), to: target, fallbackText: nil, agentName: "Codex")
        XCTAssertEqual(ok, .delivered)
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(queue.pending.isEmpty)

        queue.writer = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let target2 = fixture.paths.responseFile(requestId: "request-r2")
        let failed = await queue.send(AgentHookResponse(requestId: "request-r2", action: .reply, text: "hi"), to: target2, fallbackText: "hi", agentName: "Codex")
        XCTAssertEqual(failed, .copiedToClipboard)
        XCTAssertEqual(queue.failed.last?.attempts, 3)
        XCTAssertNotNil(queue.failed.last?.lastError)
        XCTAssertEqual(fixture.copied, ["hi"])

        // Only `responses/<requestId>.json` is ever written.
        let outside = await queue.send(AgentHookResponse(requestId: "request-r3", action: .allow), to: URL(fileURLWithPath: "/etc/passwd"), fallbackText: nil, agentName: "Codex")
        XCTAssertEqual(outside, .failed)
        let mismatched = await queue.send(AgentHookResponse(requestId: "request-r4", action: .allow), to: target, fallbackText: nil, agentName: "Codex")
        XCTAssertEqual(mismatched, .failed, "a file named for another request is refused")
        XCTAssertEqual(fixture.toasts.last, "Couldn't reach Codex. Answer in the terminal instead.")
    }

    func testBypassWritesMarkerAndApprovesLaterRequests() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "request-a1"))
        await fixture.bridge.respond(.bypass)
        XCTAssertEqual(try fixture.response(for: "request-a1")?.action, .bypass)
        XCTAssertTrue(fixture.bridge.isBypassed("a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.bypassMarker(sessionId: "a").path))

        // A request that raced the marker is approved without showing.
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "request-a2"))
        await fixture.settle { (try? fixture.response(for: "request-a2")) != nil }
        XCTAssertEqual(try fixture.response(for: "request-a2")?.action, .allow)
        XCTAssertNil(fixture.bridge.currentSession)

        fixture.bridge.setBypass(false, sessionId: "a")
        XCTAssertFalse(fixture.bridge.isBypassed("a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.bypassMarker(sessionId: "a").path))
    }

    func testCLIBypassModeShowsTheBadge() {
        let fixture = makeFixture()
        var update = fixture.update(.stop, session: "a", request: "request-a1")
        update.permissionMode = "bypassPermissions"
        fixture.bridge.ingest(update)
        XCTAssertTrue(fixture.bridge.isBypassed("a"))
    }

    func testDisableForSessionWritesMarker() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a/1", request: "request-a1"))
        await fixture.bridge.disableCurrentSession()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.disabledMarker(sessionId: "a/1").path))
        XCTAssertEqual(try fixture.response(for: "request-a1")?.action, .dismiss)
        XCTAssertNil(fixture.bridge.currentSession)
    }

    func testSpokenAllowAndDenyAnswerPermissions() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "request-a1"))
        await fixture.bridge.receiveDictation("Allow.")
        XCTAssertEqual(try fixture.response(for: "request-a1")?.action, .allow)

        fixture.bridge.ingest(fixture.update(.permission, session: "b", request: "request-b1"))
        await fixture.bridge.receiveDictation("Use the staging database instead")
        XCTAssertEqual(fixture.bridge.draft, "Use the staging database instead")
        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "request-b1"), AgentHookResponse(requestId: "request-b1", action: .deny, text: "Use the staging database instead"))
    }

    func testPlanApproveAndFeedback() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.plan, session: "a", request: "request-a1", message: "## Plan"))
        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "request-a1")?.action, .approvePlan)

        fixture.bridge.ingest(fixture.update(.plan, session: "a", request: "request-a2"))
        await fixture.bridge.receiveDictation("Do the tests first")
        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "request-a2"), AgentHookResponse(requestId: "request-a2", action: .rejectPlan, text: "Do the tests first"))
    }

    func testTurnedOffIgnoresInboxAndStateSaysSo() throws {
        let fixture = makeFixture(enabled: false)
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1"))
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertFalse(fixture.bridge.isWaiting)

        let state = try JSONDecoder().decode(AgentHookState.self, from: Data(contentsOf: fixture.paths.stateFile))
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.appPid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(state.responseTimeout, 300)

        fixture.settings.agent.enabled = true
        fixture.settings.agent.responseTimeout = 5
        fixture.bridge.writeHookState()
        let updated = try JSONDecoder().decode(AgentHookState.self, from: Data(contentsOf: fixture.paths.stateFile))
        XCTAssertTrue(updated.enabled)
        XCTAssertEqual(updated.responseTimeout, 30, "clamped to the minimum")
    }

    func testUnknownSessionThrows() async {
        let fixture = makeFixture()
        do {
            _ = try await fixture.bridge.respondOrThrow(.allow, requestId: "request-missing")
            XCTFail("expected sessionNotFound")
        } catch {
            XCTAssertEqual(error as? AgentBridgeError, .sessionNotFound)
        }
    }

    // MARK: - Links (untrusted)

    func testLinkRequestShowsWithoutDetailsAndDismisses() throws {
        let fixture = makeFixture()
        fixture.bridge.handle(url: fixture.link(.stop, request: "request-l1"))
        let session = try XCTUnwrap(fixture.bridge.currentSession)
        XCTAssertFalse(session.trusted)
        XCTAssertEqual(session.summary, AgentSession.detailsUnavailable)
        XCTAssertEqual(session.message, "")
        XCTAssertEqual(session.project, "app")
        XCTAssertEqual(fixture.panel.shows, [false])
        XCTAssertFalse(fixture.bridge.isAcceptingDictation, "a link never captures dictation")

        let dismiss = AgentDeepLink(kind: .dismiss, requestId: "request-l1", agent: .claude, event: nil, project: nil)
        fixture.bridge.handle(url: try XCTUnwrap(dismiss.url))
        XCTAssertNil(fixture.bridge.currentSession)
    }

    func testLinkCannotTouchInboxSessions() throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "request-a1"))
        // A link reusing the inbox request id neither replaces nor dismisses it.
        fixture.bridge.handle(url: fixture.link(.stop, request: "request-a1"))
        let dismiss = AgentDeepLink(kind: .dismiss, requestId: "request-a1", agent: .claude, event: nil, project: nil)
        fixture.bridge.handle(url: try XCTUnwrap(dismiss.url))
        let inbox = fixture.bridge.store.sessions.filter(\.trusted)
        XCTAssertEqual(inbox.map(\.event), [.permission])
        XCTAssertEqual(fixture.bridge.currentSession?.trusted, true)
    }

    func testCraftedLinkWritesNothingOutsideResponses() async throws {
        let fixture = makeFixture()
        let evil = fixture.temp.appendingPathComponent("evil.json")
        let crafted = [
            "parrot://agent-update?request=../../../evil&agent=claude&event=stop",
            "parrot://agent-update?request=..%2F..%2Fevil&agent=claude&event=stop",
            "parrot://agent-update?request=x&agent=claude&event=stop",
            "parrot://agent-update?payload=e30&agent=claude&event=stop",
        ]
        for text in crafted {
            fixture.bridge.handle(url: try XCTUnwrap(URL(string: text)))
        }
        XCTAssertNil(fixture.bridge.currentSession, "malformed links are dropped")

        // A valid link with a response path in it: the path is ignored.
        let withPath = try XCTUnwrap(URL(string: "parrot://agent-update?request=request-l1&agent=claude&event=stop&responseFile=\(evil.path)"))
        fixture.bridge.handle(url: withPath)
        await fixture.bridge.respond(.reply, text: "hello")
        XCTAssertEqual(try fixture.response(for: "request-l1")?.text, "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evil.path))
        let responses = fixture.allFiles().filter { $0.contains("responses/") }
        XCTAssertEqual(responses, ["root/agent/responses/request-l1.json"])
        XCTAssertTrue(fixture.allFiles().allSatisfy { $0.hasPrefix("root/agent/") }, "\(fixture.allFiles())")
    }

    func testLinkPermissionCannotBypassOrAlwaysAllow() async throws {
        let fixture = makeFixture()
        fixture.bridge.handle(url: fixture.link(.permission, request: "request-l1"))
        let session = try XCTUnwrap(fixture.bridge.currentSession)

        for action in [AgentHookResponse.Action.bypass, .allowAlways, .allowSession] {
            let outcome = await fixture.bridge.respond(action, explicit: true)
            XCTAssertEqual(outcome, .refused, action.rawValue)
        }
        // Allow needs an explicit click: not by default, not by voice.
        let unclicked = await fixture.bridge.respond(.allow)
        XCTAssertEqual(unclicked, .refused)
        await fixture.bridge.receiveDictation("allow")
        XCTAssertNil(try fixture.response(for: "request-l1"), "nothing written yet")
        XCTAssertFalse(fixture.bridge.isBypassed(session.sessionId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.bypassMarker(sessionId: session.sessionId).path))
        XCTAssertEqual(fixture.bridge.currentSession?.requestId, "request-l1", "a refused choice keeps the request")

        let clicked = await fixture.bridge.respond(.allow, explicit: true)
        XCTAssertEqual(clicked, .delivered)
        XCTAssertEqual(try fixture.response(for: "request-l1"), AgentHookResponse(requestId: "request-l1", action: .allow))
    }

    func testLinkPlanNeedsAClickAndBypassedSessionsStayManual() async throws {
        let fixture = makeFixture()
        // A trusted session with bypass on does not make a link auto-approve.
        fixture.bridge.setBypass(true, sessionId: "a")
        fixture.bridge.handle(url: fixture.link(.permission, request: "request-l1"))
        await fixture.settle { false }
        XCTAssertNil(try fixture.response(for: "request-l1"))
        await fixture.bridge.respond(.deny)
        XCTAssertEqual(try fixture.response(for: "request-l1")?.action, .deny)

        fixture.bridge.handle(url: fixture.link(.plan, request: "request-l2"))
        await fixture.bridge.sendDraft()
        XCTAssertNil(try fixture.response(for: "request-l2"), "an empty draft would approve: refused without a click")
        await fixture.bridge.respond(.approvePlan, explicit: true)
        XCTAssertEqual(try fixture.response(for: "request-l2")?.action, .approvePlan)
    }

    // MARK: - Pipeline Routing

    func testRouteStageSendsDictationToTheEditor() async throws {
        let fixture = makeFixture()
        let services = AppServices(vocabulary: VocabularyManager(storageURL: fixture.temp.appendingPathComponent("vocabulary.json")))
        services.agent = fixture.bridge
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1"))
        XCTAssertTrue(fixture.panel.isVisible)

        let session = DictationSession(trigger: .pushToTalk)
        await AgentParticipant(services: services).willStart(session)
        XCTAssertTrue(session.isAgent)
        session.text = "Add a test for it"
        let result = try await AgentRouteStage(services: services).run(session)
        XCTAssertEqual(result, .finish(.routedToAgent))
        XCTAssertEqual(session.outcome, .routedToAgent)
        XCTAssertEqual(fixture.bridge.draft, "Add a test for it")

        let empty = DictationSession(trigger: .pushToTalk)
        empty.isAgent = true
        empty.text = "  "
        let emptyResult = try await AgentRouteStage(services: services).run(empty)
        XCTAssertEqual(emptyResult, .finish(.empty))
        XCTAssertEqual(fixture.bridge.draft, "Add a test for it", "an empty dictation keeps the panel as it was")
    }

    func testRouteStageLeavesOtherDictationsAlone() async throws {
        let fixture = makeFixture()
        let services = AppServices(vocabulary: VocabularyManager(storageURL: fixture.temp.appendingPathComponent("vocabulary.json")))
        services.agent = fixture.bridge

        // No agent waiting: not an agent recording.
        let plain = DictationSession(trigger: .pushToTalk)
        await AgentParticipant(services: services).willStart(plain)
        XCTAssertFalse(plain.isAgent)
        plain.text = "Hello"
        let plainResult = try await AgentRouteStage(services: services).run(plain)
        XCTAssertEqual(plainResult, .continue)

        // A link request on screen does not capture dictation either.
        fixture.bridge.handle(url: fixture.link(.stop, request: "request-l1"))
        let linked = DictationSession(trigger: .pushToTalk)
        await AgentParticipant(services: services).willStart(linked)
        XCTAssertFalse(linked.isAgent)
        await fixture.bridge.dismissCurrent()

        // A file run never routes, even with a session waiting.
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a1"))
        let file = DictationSession(trigger: .menu, source: .file(fixture.temp.appendingPathComponent("a.wav")))
        await AgentParticipant(services: services).willStart(file)
        XCTAssertFalse(file.isAgent)

        // Flag latched but the session vanished: deliver normally.
        let latched = DictationSession(trigger: .pushToTalk)
        await AgentParticipant(services: services).willStart(latched)
        XCTAssertTrue(latched.isAgent)
        await fixture.bridge.dismissCurrent()
        latched.text = "Hello again"
        let latchedResult = try await AgentRouteStage(services: services).run(latched)
        XCTAssertEqual(latchedResult, .continue)
    }
}
