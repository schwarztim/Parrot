import Foundation
import Observation

/// Shows and hides the agent panel. `AgentPanelController` is the real
/// one; tests pass a fake.
@MainActor
protocol AgentPanelPresenting: AnyObject {
    var isVisible: Bool { get }
    /// `activate` true when the user asked for the panel: it may take
    /// keyboard focus. False for agent-driven updates: it never steals focus.
    func show(activate: Bool)
    /// `restoreFocus` returns keyboard focus to the app the user was in.
    func hide(restoreFocus: Bool)
}

enum AgentBridgeError: Error, Equatable {
    case sessionNotFound
}

/// Connects Parrot to coding agents through the hook helper and
/// `parrot://agent-*` URLs. [AGT]
///
/// The helper drops one JSON file per request into `agent/inbox/`; the
/// bridge reads it, queues the session in `store`, shows the panel without
/// stealing focus, and writes the user's answer back through `delivery`.
/// Sessions whose helper exits are dropped. A dictation finished while a
/// session waits and the panel shows lands in `draft` instead of being
/// pasted (see `AgentRouteStage`).
///
/// For the mini recorder (UI): read `currentSession`, `waitingCount` and
/// `isWaiting`, and call `showPanel()`.
@MainActor
@Observable
final class AgentBridge {

    /// The session queue. Replaced by `configure` with the persisted one.
    private(set) var store = AgentSessionStore()
    /// The pending reply for the shown session (the panel's editor).
    var draft = ""
    /// Step-by-step answers when the shown session asks questions.
    var elicitation: AgentElicitation?
    /// Mirrors the presenter, so views and the router can observe it.
    private(set) var panelVisible = false

    @ObservationIgnored var panel: AgentPanelPresenting?
    @ObservationIgnored var isProcessAlive: (Int32) -> Bool = agentHookProcessIsAlive
    @ObservationIgnored private(set) var delivery: AgentDeliveryQueue?
    @ObservationIgnored private(set) var hookPaths: AgentHookPaths?
    @ObservationIgnored private var settings: AgentSettings?
    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var draftRequestId: String?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?

    init() {}

    // MARK: - Setup

    func start(services: AppServices) {
        self.services = services
        let control = AgentHookPaths.defaultControlDir
        configure(root: services.paths.root, controlDir: control, settings: services.settings?.agent)
        delivery?.copyToClipboard = { [weak services] text in
            guard let services else { return }
            let ticket = services.output.clipboard.write(text, transient: false)
            services.output.clipboard.finish(ticket, restoreAfter: nil)
        }
        delivery?.notify = { [weak services] message in services?.showTransientError(message) }
        panel = AgentPanelController(bridge: self, services: services)
        observeSettings()
        startWatching()
        if isEnabled, store.current != nil { showPanel(activate: false) }
    }

    /// Points the bridge at a root folder and loads the saved queue. `start`
    /// calls it; tests call it directly with temp folders.
    func configure(root: URL, controlDir: URL, settings: AgentSettings?) {
        let paths = AgentHookPaths(root: root, controlDir: controlDir)
        hookPaths = paths
        self.settings = settings
        store = AgentSessionStore(fileURL: paths.agentDir.appendingPathComponent("sessions.json"))
        store.load(isAlive: isProcessAlive)
        delivery = AgentDeliveryQueue(
            responsesDirectory: paths.responses,
            fileURL: paths.agentDir.appendingPathComponent("message-queue.json")
        )
        try? FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.responses, withIntermediateDirectories: true)
        writeHookState()
        resetPanelState()
    }

    // MARK: - State for the UI

    var isEnabled: Bool { settings?.enabled ?? false }

    /// The session the panel shows.
    var currentSession: AgentSession? { store.current }

    /// Sessions waiting, the shown one included.
    var waitingCount: Int { store.sessions.count }

    /// An agent is waiting on the user.
    var isWaiting: Bool { isEnabled && store.current != nil }

    /// A dictation now would go to the agent instead of being pasted.
    var isAcceptingDictation: Bool { isWaiting && panelVisible }

    func isBypassed(_ sessionId: String) -> Bool { store.bypassed.contains(sessionId) }

    func showPanel(activate: Bool = true) {
        guard store.current != nil else { return }
        panel?.show(activate: activate)
        panelVisible = panel?.isVisible ?? false
    }

    func hidePanel(restoreFocus: Bool = true) {
        panel?.hide(restoreFocus: restoreFocus)
        panelVisible = false
    }

    // MARK: - URLs

    /// Handles a `parrot://agent-*` URL forwarded by URLRouter.
    func handle(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        diagLog("[Parrot:Agent] URL \(host)")
        switch host {
        case "agent-update", "agent-dismiss":
            if let message = AgentInboxMessage(deepLink: url) {
                ingest(message)
            } else if host == "agent-dismiss",
                      let session = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "session" })?.value {
                store.remove(sessionId: session)
                sessionsChanged()
            }
        case "agent-wake", "agent-show":
            showPanel(activate: true)
        default:
            break
        }
    }

    // MARK: - Inbox

    /// Reads every complete file in the inbox, oldest first, and deletes it.
    func scanInbox() {
        guard let inbox = hookPaths?.inbox,
              let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        else { return }
        let ready = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in ready.prefix(200) {
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            guard let data, let message = try? JSONDecoder().decode(AgentInboxMessage.self, from: data) else { continue }
            ingest(message)
        }
    }

    /// Applies one message from the helper.
    func ingest(_ incoming: AgentInboxMessage) {
        guard isEnabled, let paths = hookPaths else { return }
        var message = incoming
        // Only answer into Parrot's own responses folder.
        if let file = message.responseFile,
           URL(fileURLWithPath: file).standardizedFileURL.deletingLastPathComponent().path != paths.responses.standardizedFileURL.path {
            message.responseFile = nil
        }
        var fullText: String?
        if let file = message.messageFile {
            let url = URL(fileURLWithPath: file).standardizedFileURL
            if url.deletingLastPathComponent().path == paths.messages.standardizedFileURL.path {
                fullText = try? String(contentsOf: url, encoding: .utf8)
                try? FileManager.default.removeItem(at: url)
            }
        }
        if message.kind == .update, message.permissionMode == "bypassPermissions", !store.bypassed.contains(message.sessionId) {
            setBypass(true, sessionId: message.sessionId)
        }

        let change = store.apply(message, fullText: fullText)
        diagLog("[Parrot:Agent] \(message.agent.rawValue) \(message.kind.rawValue) \(message.event?.rawValue ?? "") -> \(change)")

        // A bypassed session's permission request is approved at once.
        if message.kind == .update, message.event == .permission, store.bypassed.contains(message.sessionId) {
            let requestId = message.requestId
            Task { await self.respond(.allow, requestId: requestId) }
            return
        }
        sessionsChanged()
    }

    /// Keeps the panel and its editor in step with the queue.
    private func sessionsChanged() {
        resetPanelState()
        if store.current == nil {
            if panelVisible { hidePanel(restoreFocus: true) }
        } else if !panelVisible {
            showPanel(activate: false)
        }
    }

    /// Clears the editor and question state when the shown request changes.
    private func resetPanelState() {
        let current = store.current
        guard current?.requestId != draftRequestId else { return }
        draftRequestId = current?.requestId
        draft = ""
        if let questions = current?.questions, current?.event == .question {
            elicitation = AgentElicitation(questions: questions)
        } else {
            elicitation = nil
        }
    }

    // MARK: - Answering

    /// Sends `action` for the shown session (or `requestId`), then drops
    /// that session and shows the next. Returns nil when the session is gone.
    @discardableResult
    func respond(
        _ action: AgentHookResponse.Action,
        text: String? = nil,
        answers: [String: [String]]? = nil,
        suggestionIndex: Int? = nil,
        requestId: String? = nil
    ) async -> AgentDeliveryQueue.Outcome? {
        guard let session = requestId.map({ store.session(requestId: $0) }) ?? store.current,
              let delivery
        else { return nil }
        store.setStatus(.sending, requestId: session.requestId)
        let response = AgentHookResponse(
            requestId: session.requestId, action: action, text: text,
            answers: answers, suggestionIndex: suggestionIndex
        )
        // A helper that has exited reads nothing: go straight to the fallback.
        let alive = session.hookPid.map(isProcessAlive) ?? false
        let fallback: String? = switch action {
        case .reply, .deny, .rejectPlan: text
        case .answer: answers.map { Self.answerText($0) }
        default: nil
        }
        let outcome = await delivery.send(
            response, to: alive ? session.responseFile : nil,
            fallbackText: fallback, agentName: session.agentName
        )
        if action == .bypass { setBypass(true, sessionId: session.sessionId) }
        store.remove(requestId: session.requestId)
        sessionsChanged()
        return outcome
    }

    /// Like `respond`, but throws when the session no longer exists.
    func respondOrThrow(_ action: AgentHookResponse.Action, text: String? = nil, requestId: String) async throws -> AgentDeliveryQueue.Outcome {
        guard let outcome = await respond(action, text: text, requestId: requestId) else {
            throw AgentBridgeError.sessionNotFound
        }
        return outcome
    }

    /// Sends the editor's text as the reply (or plan feedback, or a denial
    /// message, by the shown request's kind).
    func sendDraft() async {
        guard let session = store.current else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.event {
        case .stop:
            guard !text.isEmpty else { return }
            await respond(.reply, text: text)
        case .plan:
            await respond(text.isEmpty ? .approvePlan : .rejectPlan, text: text.isEmpty ? nil : text)
        case .permission:
            await respond(.deny, text: text.isEmpty ? nil : text)
        case .question:
            if !text.isEmpty { elicitation?.setFreeText(text) }
            await sendAnswers()
        }
    }

    /// Sends every collected answer for the shown question session.
    func sendAnswers() async {
        guard let elicitation, elicitation.isComplete else { return }
        await respond(.answer, answers: elicitation.answers())
    }

    /// Picks an option on the current question step; finishing the last
    /// single-select step sends, an earlier one advances.
    func chooseOption(_ label: String) async {
        guard var state = elicitation else { return }
        let finished = state.choose(label)
        elicitation = state
        if finished { await advanceOrSend() }
    }

    func advanceOrSend() async {
        guard var state = elicitation else { return }
        if state.next() {
            elicitation = state
        } else if state.isComplete {
            await sendAnswers()
        }
    }

    /// Lets the CLI's own terminal prompt take over for the shown session.
    func dismissCurrent() async {
        await respond(.dismiss)
    }

    /// "Disable Parrot for this session": the helper stays quiet for it
    /// until the user types "enable parrot" in the terminal.
    func disableCurrentSession() async {
        guard let session = store.current, let paths = hookPaths else { return }
        writeMarker(paths.disabledMarker(sessionId: session.sessionId), present: true)
        await respond(.dismiss, requestId: session.requestId)
        store.remove(sessionId: session.sessionId)
        sessionsChanged()
    }

    /// Turns Parrot's bypass on or off for a session. On, the helper allows
    /// that session's permission requests without asking.
    func setBypass(_ on: Bool, sessionId: String) {
        store.setBypassed(on, sessionId: sessionId)
        if let paths = hookPaths {
            writeMarker(paths.bypassMarker(sessionId: sessionId), present: on)
        }
    }

    // MARK: - Dictation

    private static let allowWords: Set<String> = ["allow", "yes", "approve", "allow it", "yes allow", "go ahead", "ok", "okay"]
    private static let denyWords: Set<String> = ["deny", "no", "reject", "deny it", "don't", "do not"]

    /// A finished dictation for the shown session. Returns false when no
    /// session is waiting (the caller then delivers the text normally).
    /// `autoSend` (Shift held at stop) sends a reply right away.
    @discardableResult
    func receiveDictation(_ text: String, autoSend: Bool = false) async -> Bool {
        guard isEnabled, let session = store.current else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        switch session.event {
        case .stop, .plan:
            appendToDraft(trimmed)
            if autoSend, session.event == .stop { await sendDraft() }
        case .permission:
            let said = AgentElicitation.normalize(trimmed)
            if Self.allowWords.contains(said) {
                await respond(.allow)
            } else if Self.denyWords.contains(said) {
                await respond(.deny)
            } else {
                appendToDraft(trimmed)
            }
        case .question:
            guard var state = elicitation else {
                appendToDraft(trimmed)
                return true
            }
            let finished = state.applySpoken(trimmed)
            elicitation = state
            if finished, autoSend || !state.isLastStep { await advanceOrSend() }
        }
        return true
    }

    private func appendToDraft(_ text: String) {
        draftRequestId = store.current?.requestId
        draft = draft.isEmpty ? text : draft + (draft.hasSuffix("\n") ? "" : " ") + text
    }

    /// Question answers as text, for the clipboard fallback.
    static func answerText(_ answers: [String: [String]]) -> String {
        answers.keys.sorted().map { "\($0) \(answers[$0]!.joined(separator: ", "))" }.joined(separator: "\n")
    }

    // MARK: - Watching

    private func startWatching() {
        guard let inbox = hookPaths?.inbox else { return }
        scanInbox()
        let descriptor = open(inbox.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scanInbox() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
        // Backup scan and helper-exit check.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Rescans the inbox and drops sessions whose helper has exited.
    func tick() {
        scanInbox()
        let dead = store.pruneDeadProcesses(isAlive: isProcessAlive)
        for session in dead { delivery?.cancel(requestId: session.requestId) }
        if !dead.isEmpty { sessionsChanged() }
    }

    // MARK: - Settings and Shared State

    private func observeSettings() {
        guard let settings else { return }
        withObservationTracking {
            _ = settings.enabled
            _ = settings.responseTimeout
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.settingsChanged()
                self?.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        writeHookState()
        guard !isEnabled else { return }
        // Turned off: let every waiting helper go so the CLIs ask in the terminal.
        let waiting = store.sessions
        Task {
            for session in waiting { await self.respond(.dismiss, requestId: session.requestId) }
        }
    }

    /// Tells the helper whether Parrot is listening and how long to wait.
    func writeHookState() {
        guard let paths = hookPaths else { return }
        let state = AgentHookState(
            enabled: isEnabled,
            appPid: ProcessInfo.processInfo.processIdentifier,
            responseTimeout: settings?.clampedResponseTimeout ?? 300
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? AgentHookPaths.writeAtomically(data, to: paths.stateFile)
    }

    private func writeMarker(_ url: URL, present: Bool) {
        if present {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            FileManager.default.createFile(atPath: url.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
