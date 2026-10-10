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

    var paths: AgentHookPaths { bridge.hookPaths! }

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
            responseFile: paths.responseFile(requestId: request).path,
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

    /// Drops `message` into the inbox the way the helper does.
    func drop(_ message: AgentInboxMessage, order: Int) throws {
        let name = String(format: "%013d-%@-%@.json", order, message.requestId, message.kind.rawValue)
        try AgentHookPaths.writeAtomically(try JSONEncoder().encode(message), to: paths.inbox.appendingPathComponent(name))
    }

    func response(for request: String) throws -> AgentHookResponse? {
        let file = paths.responseFile(requestId: request)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try JSONDecoder().decode(AgentHookResponse.self, from: data)
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
        XCTAssertEqual(store.apply(fixture.update(.stop, session: "a", request: "a1")), .shown)
        XCTAssertEqual(store.apply(fixture.update(.permission, session: "b", request: "b1")), .queued)
        XCTAssertEqual(store.apply(fixture.update(.stop, session: "c", request: "c1")), .queued)
        XCTAssertEqual(store.current?.sessionId, "a")
        XCTAssertEqual(store.queued.map(\.sessionId), ["b", "c"])
        XCTAssertEqual(store.queued.first?.status, .permissionNeeded)

        // A newer request for b replaces it where it stands.
        XCTAssertEqual(store.apply(fixture.update(.question, session: "b", request: "b2")), .replaced)
        XCTAssertEqual(store.sessions.map(\.requestId), ["a1", "b2", "c1"])
        XCTAssertEqual(store.sessions[1].status, .question)
    }

    func testDismissMatchesRequestOrWholeSession() {
        let store = AgentSessionStore()
        let fixture = makeFixture()
        store.apply(fixture.update(.stop, session: "a", request: "a2"))
        store.apply(fixture.update(.stop, session: "b", request: "b1"))

        // A late dismiss for an older request leaves the newer one alone.
        XCTAssertEqual(store.apply(.dismiss(agent: .claude, sessionId: "a", requestId: "a1", hookPid: nil)), .ignored)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.apply(.dismiss(agent: .claude, sessionId: "a", requestId: "a2", hookPid: nil)), .removed)
        // An empty request id (the user typed in the terminal) clears the session.
        XCTAssertEqual(store.apply(.dismiss(agent: .claude, sessionId: "b", requestId: "", hookPid: nil)), .removed)
        XCTAssertNil(store.current)
    }

    func testPersistsAcrossRelaunchAndDropsDeadHelpers() {
        let fixture = makeFixture()
        let file = fixture.temp.appendingPathComponent("sessions.json")
        let store = AgentSessionStore(fileURL: file)
        store.apply(fixture.update(.stop, session: "a", request: "a1", pid: 100))
        store.apply(fixture.update(.permission, session: "b", request: "b1", pid: 200))
        store.setBypassed(true, sessionId: "b")
        store.setStatus(.sending, requestId: "a1")

        let relaunched = AgentSessionStore(fileURL: file)
        relaunched.load { $0 == 100 }
        XCTAssertEqual(relaunched.sessions.map(\.requestId), ["a1"])
        XCTAssertEqual(relaunched.current?.status, .completed, "a send cut off by quitting is shown again")
        XCTAssertEqual(relaunched.current?.message, "Done.")
        XCTAssertEqual(relaunched.bypassed, ["b"])
    }

    func testPruneDropsSessionsWhoseHelperExited() {
        let store = AgentSessionStore()
        let fixture = makeFixture()
        store.apply(fixture.update(.stop, session: "a", request: "a1", pid: 100))
        store.apply(fixture.update(.stop, session: "b", request: "b1", pid: 101))
        let dead = store.pruneDeadProcesses { $0 == 101 }
        XCTAssertEqual(dead.map(\.sessionId), ["a"])
        XCTAssertEqual(store.current?.sessionId, "b")
    }

    // MARK: - Bridge

    func testInboxShowsPanelWithoutTakingFocus() throws {
        let fixture = makeFixture()
        try fixture.drop(fixture.update(.stop, session: "a", request: "a1", message: "All **done**.\nTests pass."), order: 1)
        try fixture.drop(fixture.update(.stop, session: "b", request: "b1"), order: 2)
        fixture.bridge.scanInbox()

        XCTAssertEqual(fixture.bridge.currentSession?.sessionId, "a")
        XCTAssertEqual(fixture.bridge.currentSession?.summary, "All **done**.")
        XCTAssertEqual(fixture.bridge.waitingCount, 2)
        XCTAssertEqual(fixture.panel.shows, [false], "agent updates never steal focus")
        XCTAssertTrue(fixture.bridge.isAcceptingDictation)
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.inbox.path)
        XCTAssertEqual(left, [], "processed inbox files are deleted")
    }

    func testReplyWritesResponseAndPromotesNext() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1"))
        fixture.bridge.ingest(fixture.update(.stop, session: "b", request: "b1"))
        await fixture.bridge.receiveDictation("Run the linter")
        await fixture.bridge.receiveDictation("then commit")
        XCTAssertEqual(fixture.bridge.draft, "Run the linter then commit")

        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "a1"), AgentHookResponse(requestId: "a1", action: .reply, text: "Run the linter then commit"))
        XCTAssertEqual(fixture.bridge.currentSession?.sessionId, "b")
        XCTAssertEqual(fixture.bridge.draft, "", "the editor clears for the next session")

        await fixture.bridge.dismissCurrent()
        XCTAssertEqual(try fixture.response(for: "b1")?.action, .dismiss)
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertGreaterThan(fixture.panel.hides, 0)
    }

    func testShiftHeldAutoSendsTheReply() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1"))
        await fixture.bridge.receiveDictation("Ship it", autoSend: true)
        XCTAssertEqual(try fixture.response(for: "a1")?.text, "Ship it")
    }

    func testDeadHelperSendsReplyToClipboard() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1", pid: 100))
        fixture.alive = []
        fixture.bridge.draft = "Keep this text"
        await fixture.bridge.sendDraft()
        XCTAssertNil(try fixture.response(for: "a1"))
        XCTAssertEqual(fixture.copied, ["Keep this text"])
        XCTAssertEqual(fixture.toasts, ["Couldn't reach Claude Code. Your reply is on the clipboard."])
    }

    func testTickDropsSessionsWhoseHelperExited() {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1", pid: 100))
        fixture.bridge.ingest(fixture.update(.stop, session: "b", request: "b1", pid: 101))
        fixture.alive = [101]
        fixture.bridge.tick()
        XCTAssertEqual(fixture.bridge.currentSession?.sessionId, "b")
        fixture.alive = []
        fixture.bridge.tick()
        XCTAssertNil(fixture.bridge.currentSession)
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testDeliveryRetriesThenFallsBack() async throws {
        let fixture = makeFixture()
        let queue = try XCTUnwrap(fixture.bridge.delivery)
        var calls = 0
        queue.writer = { _, _ in
            calls += 1
            if calls < 3 { throw CocoaError(.fileWriteNoPermission) }
        }
        let target = fixture.paths.responseFile(requestId: "r1").path
        let ok = await queue.send(AgentHookResponse(requestId: "r1", action: .allow), to: target, fallbackText: nil, agentName: "Codex")
        XCTAssertEqual(ok, .delivered)
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(queue.pending.isEmpty)

        queue.writer = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let failed = await queue.send(AgentHookResponse(requestId: "r2", action: .reply, text: "hi"), to: target, fallbackText: "hi", agentName: "Codex")
        XCTAssertEqual(failed, .copiedToClipboard)
        XCTAssertEqual(queue.failed.last?.attempts, 3)
        XCTAssertNotNil(queue.failed.last?.lastError)
        XCTAssertEqual(fixture.copied, ["hi"])

        let refused = await queue.send(AgentHookResponse(requestId: "r3", action: .allow), to: "/etc/passwd", fallbackText: nil, agentName: "Codex")
        XCTAssertEqual(refused, .failed, "only Parrot's responses folder is written")
        XCTAssertEqual(fixture.toasts.last, "Couldn't reach Codex. Answer in the terminal instead.")
    }

    func testForeignResponsePathIsDropped() async throws {
        let fixture = makeFixture()
        var update = fixture.update(.stop, session: "a", request: "a1")
        update.responseFile = fixture.temp.appendingPathComponent("elsewhere.json").path
        fixture.bridge.ingest(update)
        XCTAssertNil(fixture.bridge.currentSession?.responseFile)
        await fixture.bridge.respond(.reply, text: "hello")
        XCTAssertEqual(fixture.copied, ["hello"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: update.responseFile!))
    }

    func testBypassWritesMarkerAndApprovesLaterRequests() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "a1"))
        await fixture.bridge.respond(.bypass)
        XCTAssertEqual(try fixture.response(for: "a1")?.action, .bypass)
        XCTAssertTrue(fixture.bridge.isBypassed("a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.bypassMarker(sessionId: "a").path))

        // A request that raced the marker is approved without showing.
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "a2"))
        await fixture.settle { (try? fixture.response(for: "a2")) != nil }
        XCTAssertEqual(try fixture.response(for: "a2")?.action, .allow)
        XCTAssertNil(fixture.bridge.currentSession)

        fixture.bridge.setBypass(false, sessionId: "a")
        XCTAssertFalse(fixture.bridge.isBypassed("a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.bypassMarker(sessionId: "a").path))
    }

    func testCLIBypassModeShowsTheBadge() {
        let fixture = makeFixture()
        var update = fixture.update(.stop, session: "a", request: "a1")
        update.permissionMode = "bypassPermissions"
        fixture.bridge.ingest(update)
        XCTAssertTrue(fixture.bridge.isBypassed("a"))
    }

    func testDisableForSessionWritesMarker() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.stop, session: "a/1", request: "a1"))
        await fixture.bridge.disableCurrentSession()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.disabledMarker(sessionId: "a/1").path))
        XCTAssertEqual(try fixture.response(for: "a1")?.action, .dismiss)
        XCTAssertNil(fixture.bridge.currentSession)
    }

    func testSpokenAllowAndDenyAnswerPermissions() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.permission, session: "a", request: "a1"))
        await fixture.bridge.receiveDictation("Allow.")
        XCTAssertEqual(try fixture.response(for: "a1")?.action, .allow)

        fixture.bridge.ingest(fixture.update(.permission, session: "b", request: "b1"))
        await fixture.bridge.receiveDictation("Use the staging database instead")
        XCTAssertEqual(fixture.bridge.draft, "Use the staging database instead")
        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "b1"), AgentHookResponse(requestId: "b1", action: .deny, text: "Use the staging database instead"))
    }

    func testPlanApproveAndFeedback() async throws {
        let fixture = makeFixture()
        fixture.bridge.ingest(fixture.update(.plan, session: "a", request: "a1", message: "## Plan"))
        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "a1")?.action, .approvePlan)

        fixture.bridge.ingest(fixture.update(.plan, session: "a", request: "a2"))
        await fixture.bridge.receiveDictation("Do the tests first")
        await fixture.bridge.sendDraft()
        XCTAssertEqual(try fixture.response(for: "a2"), AgentHookResponse(requestId: "a2", action: .rejectPlan, text: "Do the tests first"))
    }

    func testTurnedOffIgnoresInboxAndStateSaysSo() throws {
        let fixture = makeFixture(enabled: false)
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1"))
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

    func testDeepLinksUpdateAndDismiss() throws {
        let fixture = makeFixture()
        let update = fixture.update(.stop, session: "a", request: "a1")
        fixture.bridge.handle(url: try XCTUnwrap(update.deepLink))
        XCTAssertEqual(fixture.bridge.currentSession?.requestId, "a1")
        let dismiss = AgentInboxMessage.dismiss(agent: .claude, sessionId: "a", requestId: "a1", hookPid: 100)
        fixture.bridge.handle(url: try XCTUnwrap(dismiss.deepLink))
        XCTAssertNil(fixture.bridge.currentSession)

        fixture.bridge.ingest(fixture.update(.stop, session: "b", request: "b1"))
        fixture.bridge.handle(url: URL(string: "parrot://agent-dismiss?session=b")!)
        XCTAssertNil(fixture.bridge.currentSession)
    }

    func testUnknownSessionThrows() async {
        let fixture = makeFixture()
        do {
            _ = try await fixture.bridge.respondOrThrow(.allow, requestId: "missing")
            XCTFail("expected sessionNotFound")
        } catch {
            XCTAssertEqual(error as? AgentBridgeError, .sessionNotFound)
        }
    }

    // MARK: - Pipeline Routing

    func testRouteStageSendsDictationToTheEditor() async throws {
        let fixture = makeFixture()
        let services = AppServices(vocabulary: VocabularyManager(storageURL: fixture.temp.appendingPathComponent("vocabulary.json")))
        services.agent = fixture.bridge
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1"))
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

        // A file run never routes, even with a session waiting.
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "a1"))
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
