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
        if isEnabled { sessionsChanged() }
    }

    /// Points the bridge at a root folder and loads the saved queue. `start`
    /// calls it; tests call it directly with temp folders.
    ///
    /// The agent folders are made 0700 and must be real folders owned by
    /// the user; otherwise the bridge stays off (`hookPaths` nil) and
    /// nothing is read or written there.
    func configure(root: URL, controlDir: URL, settings: AgentSettings?) {
        self.settings = settings
        let paths = AgentHookPaths(root: root, controlDir: controlDir)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = [paths.agentDir, paths.inbox, paths.responses, paths.messages]
        guard folders.allSatisfy({ AgentHookPaths.secureDirectory($0, create: true) == .secure }) else {
            diagLog("[Parrot:Agent] Agent folder is not a private folder owned by this user; agent replies stay off")
            hookPaths = nil
            delivery = nil
            store = AgentSessionStore()
            resetPanelState()
            return
        }
        hookPaths = paths
        store = AgentSessionStore(fileURL: paths.agentDir.appendingPathComponent("sessions.json"))
        store.load(isAlive: isProcessAlive)
        delivery = AgentDeliveryQueue(
            responsesDirectory: paths.responses,
            fileURL: paths.agentDir.appendingPathComponent("message-queue.json")
        )
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

    /// A dictation now would go to the agent instead of being pasted. Never
    /// for a link request: a page opening a link must not capture speech.
    var isAcceptingDictation: Bool { isWaiting && panelVisible && store.current?.trusted == true }

    func isBypassed(_ sessionId: String) -> Bool { store.bypassed[sessionId] != nil }

    // MARK: - Grants Offered for a Request

    /// The suggestion "Always Allow" saves and its exact rule text, or nil
    /// when none is narrow enough (the button is then hidden).
    func alwaysAllowRule(for session: AgentSession) -> (index: Int, text: String)? {
        guard session.trusted, let permission = session.permission, permission.canUpdatePermissions,
              let index = HookPermissionRules.alwaysAllowIndex(in: permission.suggestions),
              let text = HookPermissionRules.text(of: permission.suggestions[index])
        else { return nil }
        return (index, text)
    }

    /// The suggestion "Allow for This Session" grants and its rule text.
    func sessionRule(for session: AgentSession) -> (index: Int, text: String)? {
        guard session.trusted, let permission = session.permission, permission.canUpdatePermissions,
              let index = HookPermissionRules.sessionIndex(in: permission.suggestions),
              let text = HookPermissionRules.text(of: permission.suggestions[index])
        else { return nil }
        return (index, text)
    }

    /// Bypass needs a trusted request from a CLI process Parrot can watch,
    /// so it ends when that process exits.
    func canBypass(_ session: AgentSession) -> Bool {
        session.trusted && session.event == .permission && session.cliPid.map(isProcessAlive) == true
    }

    func showPanel(activate: Bool = true) {
        guard store.current != nil || !store.bypassed.isEmpty else { return }
        panel?.show(activate: activate)
        panelVisible = panel?.isVisible ?? false
    }

    func hidePanel(restoreFocus: Bool = true) {
        panel?.hide(restoreFocus: restoreFocus)
        panelVisible = false
    }

    // MARK: - URLs

    /// Handles a `parrot://agent-*` URL forwarded by URLRouter.
    ///
    /// Anyone can open such a link, so an update becomes an untrusted
    /// session: shown with "details unavailable", answered only into
    /// `responses/<requestId>.json`, and never offered bypass, always allow
    /// or a spoken allow. A malformed link is dropped.
    func handle(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        diagLog("[Parrot:Agent] URL \(host)")
        switch host {
        case "agent-update", "agent-dismiss":
            guard isEnabled, hookPaths != nil, let link = AgentDeepLink(url: url) else { return }
            let change = store.apply(link: link)
            diagLog("[Parrot:Agent] link \(link.agent.rawValue) \(link.kind.rawValue) \(link.event?.rawValue ?? "") -> \(change)")
            sessionsChanged()
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
            // Only regular files this user owns; a symlink is removed unread.
            let data = AgentHookPaths.isPrivateFile(file) ? try? Data(contentsOf: file) : nil
            try? FileManager.default.removeItem(at: file)
            guard let data, let message = try? JSONDecoder().decode(AgentInboxMessage.self, from: data) else { continue }
            ingest(message)
        }
    }

    /// Applies one message from the helper's inbox (trusted).
    func ingest(_ message: AgentInboxMessage) {
        guard isEnabled, let paths = hookPaths else { return }
        // A full message too long to inline: read from the path derived
        // from the request id (never from the message), then delete it.
        var fullText: String?
        if message.messageInFile == true, let file = paths.messageFile(requestId: message.requestId) {
            if AgentHookPaths.isPrivateFile(file) {
                fullText = try? String(contentsOf: file, encoding: .utf8)
            }
            try? FileManager.default.removeItem(at: file)
        }
        let change = store.apply(message, fullText: fullText)
        // Kinds and names only: messages can hold code and secrets.
        diagLog("[Parrot:Agent] \(message.agent.rawValue) \(message.kind.rawValue) \(message.event?.rawValue ?? "") -> \(change)")
        guard change != .ignored else { return }

        // A CLI that reports its own bypass mode only gets a note in the
        // panel header. Parrot's bypass is granted only through its
        // confirmation: the requests a CLI still asks about in bypass mode
        // are the ones it wants a person to see.
        // A bypassed session's permission request is approved at once, if
        // it comes from the same CLI process.
        if message.kind == .update, message.event == .permission,
           let bypass = store.bypassed[message.sessionId], bypass.cliPid == message.cliPid {
            let requestId = message.requestId
            Task { await self.respond(.allow, requestId: requestId) }
            return
        }
        sessionsChanged()
    }

    /// Keeps the panel and its editor in step with the queue.
    /// The panel stays up while a session waits or a bypass is active (its
    /// badge must stay visible), and closes when neither is left.
    private func sessionsChanged() {
        resetPanelState()
        if store.current == nil, store.bypassed.isEmpty {
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

    /// Choices never honored for a request that came by link.
    static let trustedOnlyActions: Set<AgentHookResponse.Action> = [.bypass, .allowAlways, .allowSession]
    /// Choices a link request takes only from an explicit click.
    static let clickOnlyActions: Set<AgentHookResponse.Action> = [.allow, .approvePlan]

    /// Whether `action` may be sent for `session` (`explicit`: the user
    /// clicked the button or pressed its shortcut).
    func allows(_ action: AgentHookResponse.Action, for session: AgentSession, explicit: Bool) -> Bool {
        if !session.trusted {
            if Self.trustedOnlyActions.contains(action) { return false }
            if Self.clickOnlyActions.contains(action) { return explicit }
            return true
        }
        switch action {
        case .allowAlways: return alwaysAllowRule(for: session) != nil
        case .allowSession: return sessionRule(for: session) != nil
        case .bypass: return canBypass(session)
        default: return true
        }
    }

    /// Sends `action` for the shown session (or `requestId`), then drops
    /// that session and shows the next. Returns nil when the session is
    /// gone, `.refused` (and keeps the session) when a link request may not
    /// take this choice. The answer only ever goes to
    /// `responses/<requestId>.json`, derived here from a validated id.
    @discardableResult
    func respond(
        _ action: AgentHookResponse.Action,
        text: String? = nil,
        answers: [String: [String]]? = nil,
        suggestionIndex: Int? = nil,
        requestId: String? = nil,
        explicit: Bool = false
    ) async -> AgentDeliveryQueue.Outcome? {
        guard let session = requestId.map({ store.session(requestId: $0) }) ?? store.current,
              let delivery, let paths = hookPaths
        else { return nil }
        guard allows(action, for: session, explicit: explicit) else {
            diagLog("[Parrot:Agent] Refused \(action.rawValue) (trusted: \(session.trusted))")
            return .refused
        }
        store.setStatus(.sending, requestId: session.requestId)
        let response = AgentHookResponse(
            requestId: session.requestId, action: action, text: text,
            answers: answers, suggestionIndex: suggestionIndex
        )
        // A helper that has exited reads nothing: go straight to the
        // fallback. A link request has no helper id; its file is written.
        let alive = session.hookPid.map(isProcessAlive) ?? !session.trusted
        let fallback: String? = switch action {
        case .reply, .deny, .rejectPlan: text
        case .answer: answers.map { Self.answerText($0) }
        default: nil
        }
        let outcome = await delivery.send(
            response, to: alive ? paths.responseFile(requestId: session.requestId) : nil,
            fallbackText: fallback, agentName: session.agentName
        )
        if action == .bypass {
            setBypass(true, sessionId: session.sessionId, cliPid: session.cliPid, agent: session.agent, project: session.project)
        }
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
            // Never an approval: a spoken "allow" waits for the Allow button.
            guard !draftSaysAllow else { return }
            await respond(.deny, text: Self.denialMessage(text))
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
        // A link names no session Parrot can trust; just let it go.
        if session.trusted {
            writeMarker(paths.disabledMarker(sessionId: session.sessionId), present: true)
        }
        await respond(.dismiss, requestId: session.requestId)
        store.remove(sessionId: session.sessionId)
        sessionsChanged()
    }

    /// Turns Parrot's bypass on (bound to the CLI process `cliPid`) or off
    /// for a session. On, the helper allows that session's permission
    /// requests without asking while that process asks. Without a process
    /// id it stays off: a bypass must be able to end.
    func setBypass(_ on: Bool, sessionId: String, cliPid: Int32? = nil, agent: HookAgent = .claude, project: String? = nil) {
        let bypass = on ? cliPid.map { AgentBypass(cliPid: $0, agent: agent, project: project) } : nil
        guard !on || bypass != nil else { return }
        store.setBypassed(sessionId: sessionId, bypass: bypass)
        if let paths = hookPaths {
            writeMarker(paths.bypassMarker(sessionId: sessionId), present: on, contents: bypass.map { "\($0.cliPid)\n" } ?? "")
        }
        sessionsChanged()
    }

    /// Active bypasses, for the panel's badges and the mini recorder.
    var activeBypasses: [(sessionId: String, bypass: AgentBypass)] {
        store.bypassed.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Dictation

    static let allowWords: Set<String> = ["allow", "yes", "approve", "allow it", "yes allow", "go ahead", "ok", "okay"]
    static let denyWords: Set<String> = ["deny", "no", "reject", "deny it", "don t", "do not"]

    /// The message a denial carries: the draft, unless it is only a spoken
    /// allow or deny word.
    static func denialMessage(_ draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = AgentElicitation.normalize(text)
        guard !text.isEmpty, !allowWords.contains(said), !denyWords.contains(said) else { return nil }
        return text
    }

    /// The draft is a spoken allow (the panel then points at the Allow button).
    var draftSaysAllow: Bool {
        Self.allowWords.contains(AgentElicitation.normalize(draft))
    }

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
            // Speech only fills the editor. Approving or denying always
            // takes a click on Allow or Deny (or Cmd+Return for Allow).
            appendToDraft(trimmed)
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
    func tick(now: Date = Date()) {
        scanInbox()
        // Link requests have no helper to watch: they expire with the wait.
        let maxAge = settings?.clampedResponseTimeout ?? 300
        let dead = store.pruneDeadProcesses(isAlive: isProcessAlive, now: now, maxAge: maxAge)
        for session in dead { delivery?.cancel(requestId: session.requestId) }
        if !dead.isEmpty { sessionsChanged() }
        // A bypass ends with its CLI process.
        let ended = store.pruneBypass(isAlive: isProcessAlive)
        for sessionId in ended {
            if let paths = hookPaths { writeMarker(paths.bypassMarker(sessionId: sessionId), present: false) }
        }
        if !ended.isEmpty { sessionsChanged() }
        sweepOrphans(now: now)
    }

    /// Deletes response and message files nobody picked up (a helper that
    /// was killed, or an answer to a link nobody waits on) once they are
    /// older than the longest possible wait.
    func sweepOrphans(now: Date = Date()) {
        guard let paths = hookPaths else { return }
        let limit = AgentSettings.timeoutRange.upperBound + 60
        for folder in [paths.responses, paths.messages] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(modified) > limit { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    // MARK: - Settings and Shared State

    private func observeSettings() {
        guard let settings else { return }
        withObservationTracking {
            _ = settings.enabled
            _ = settings.responseTimeout
            _ = settings.claudeStopHook
            _ = settings.codexStopHook
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

    /// Tells the helper whether Parrot is listening, how long to wait, and
    /// which CLIs' Stop events to answer.
    func writeHookState() {
        guard let paths = hookPaths else { return }
        let state = AgentHookState(
            enabled: isEnabled,
            appPid: ProcessInfo.processInfo.processIdentifier,
            responseTimeout: settings?.clampedResponseTimeout ?? 300,
            stopAgents: settings?.stopHookAgents ?? []
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? AgentHookPaths.writeAtomically(data, to: paths.stateFile)
    }

    /// Creates or removes a session marker. The control folder must pass
    /// the same 0700, owner and no-symlink check the helper makes.
    private func writeMarker(_ url: URL, present: Bool, contents: String = "") {
        guard AgentHookPaths.secureDirectory(url.deletingLastPathComponent(), create: true) == .secure else {
            diagLog("[Parrot:Agent] Control folder is not private; marker not written")
            return
        }
        if present {
            try? AgentHookPaths.writeAtomically(Data(contents.utf8), to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
