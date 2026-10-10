import Foundation
import Observation

// MARK: - Session

/// Where an agent session stands.
enum AgentStatus: String, Codable, Sendable {
    case idle
    /// The turn finished; the agent waits for the next instruction.
    case completed
    case permissionNeeded
    case question
    case planReview
    /// Parrot is writing the answer.
    case sending
    case error
}

/// One coding-agent session waiting on the user: its latest request plus
/// what the panel header shows.
struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    var id: String { sessionId }

    var agent: HookAgent
    var sessionId: String
    var requestId: String
    var event: HookEvent
    var status: AgentStatus
    /// One line for queue rows and the mini recorder.
    var summary: String
    /// The agent's last message or plan, Markdown.
    var message: String
    /// True when the request came through the inbox (a folder only the
    /// user can write). False for a `parrot://` link, which anyone can
    /// open: no details, and no bypass, always allow or spoken allow.
    var trusted: Bool
    var cwd: String?
    var project: String?
    var branch: String?
    var title: String?
    var hookPid: Int32?
    /// The CLI process. Bypass is only offered when it is known, and ends
    /// when it exits.
    var cliPid: Int32?
    /// For a link request: the session id the link named (display and
    /// clean-up only; it never lets a link touch that session).
    var linkedSessionId: String?
    var permissionMode: String?
    var permission: HookPermission?
    var questions: [HookQuestion]?
    var receivedAt: Date

    /// A request from the inbox. Nil for a dismiss, a missing event or an
    /// invalid request id.
    init?(message update: AgentInboxMessage, fullText: String? = nil) {
        guard update.kind == .update, let event = update.event,
              AgentInboxMessage.isValidRequestId(update.requestId)
        else { return nil }
        agent = update.agent
        sessionId = update.sessionId
        requestId = update.requestId
        self.event = event
        status = AgentSession.status(for: event)
        summary = update.summary ?? ""
        message = fullText ?? update.message ?? ""
        trusted = true
        cwd = update.cwd
        project = update.project
        branch = update.branch
        title = update.title
        hookPid = update.hookPid
        cliPid = update.cliPid
        permissionMode = update.permissionMode
        permission = update.permission
        questions = update.questions
        receivedAt = Date(timeIntervalSince1970: update.createdAt)
    }

    /// Text shown for a request that came by link.
    static let detailsUnavailable = "Open the terminal for details."

    /// A request that came by `parrot://` link: untrusted, details hidden.
    /// Keyed by its request id so it can never replace an inbox session.
    init?(link: AgentDeepLink, receivedAt: Date = Date()) {
        guard link.kind == .update, let event = link.event else { return nil }
        agent = link.agent
        sessionId = Self.linkSessionId(link.requestId)
        linkedSessionId = link.sessionId
        requestId = link.requestId
        self.event = event
        status = AgentSession.status(for: event)
        summary = Self.detailsUnavailable
        message = ""
        trusted = false
        project = link.project
        self.receivedAt = receivedAt
    }

    static func linkSessionId(_ requestId: String) -> String { "link-" + requestId }

    static func status(for event: HookEvent) -> AgentStatus {
        switch event {
        case .stop: return .completed
        case .permission: return .permissionNeeded
        case .question: return .question
        case .plan: return .planReview
        }
    }

    /// "Claude Code", "Codex".
    var agentName: String { agent.displayName }
}

/// An active bypass: Parrot approves a session's permission requests while
/// this CLI process runs.
struct AgentBypass: Codable, Equatable, Sendable {
    var cliPid: Int32
    var agent: HookAgent
    var project: String?

    /// "Claude Code in parrot".
    var label: String {
        project.map { "\(agent.displayName) in \($0)" } ?? agent.displayName
    }
}

// MARK: - Store

/// The queue of agent sessions waiting on the user. [AGT]
///
/// Exactly one session is shown (the first); the rest are queued in arrival
/// order. A newer request for a session replaces the older one in place.
/// The queue and the bypassed sessions persist across relaunches; sessions
/// whose hook helper has exited are dropped.
@MainActor
@Observable
final class AgentSessionStore {

    /// What `apply(_:fullText:)` did.
    enum Change: Equatable {
        /// A new session became the shown one.
        case shown
        /// A new session joined the queue behind the shown one.
        case queued
        /// An existing session got a newer request.
        case replaced
        case removed
        case ignored
    }

    private(set) var sessions: [AgentSession] = []
    /// Sessions whose permission requests Parrot approves itself, by
    /// session id, each bound to the CLI process it was granted for.
    private(set) var bypassed: [String: AgentBypass] = [:]

    @ObservationIgnored private let fileURL: URL?

    /// `fileURL` nil keeps the store in memory only.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// The session the panel shows.
    var current: AgentSession? { sessions.first }

    /// Everything waiting behind the shown session.
    var queued: [AgentSession] { Array(sessions.dropFirst()) }

    func session(requestId: String) -> AgentSession? {
        sessions.first { $0.requestId == requestId }
    }

    func session(id sessionId: String) -> AgentSession? {
        sessions.first { $0.sessionId == sessionId }
    }

    // MARK: Changes

    /// Applies a message from the inbox (trusted).
    @discardableResult
    func apply(_ message: AgentInboxMessage, fullText: String? = nil) -> Change {
        switch message.kind {
        case .update:
            guard let session = AgentSession(message: message, fullText: fullText) else { return .ignored }
            // The real request supersedes a link card for the same session.
            sessions.removeAll { !$0.trusted && $0.linkedSessionId == session.sessionId }
            return insert(session)
        case .dismiss:
            // An empty request id means "anything for this session" (the user
            // typed in the terminal), link cards for it included. Otherwise
            // only that exact request goes, so a late dismiss never removes a
            // newer request.
            let before = sessions.count
            sessions.removeAll {
                if !$0.trusted {
                    return message.requestId.isEmpty && $0.linkedSessionId == message.sessionId
                }
                return $0.sessionId == message.sessionId
                    && (message.requestId.isEmpty || $0.requestId == message.requestId)
            }
            guard sessions.count != before else { return .ignored }
            save()
            return .removed
        }
    }

    /// Applies a `parrot://` link (untrusted). It only ever adds or removes
    /// link sessions; inbox sessions are out of its reach.
    @discardableResult
    func apply(link: AgentDeepLink) -> Change {
        switch link.kind {
        case .update:
            guard let session = AgentSession(link: link) else { return .ignored }
            return insert(session)
        case .dismiss:
            let before = sessions.count
            sessions.removeAll { !$0.trusted && $0.requestId == link.requestId }
            guard sessions.count != before else { return .ignored }
            save()
            return .removed
        }
    }

    private func insert(_ session: AgentSession) -> Change {
        if let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[index] = session
            save()
            return .replaced
        }
        sessions.append(session)
        save()
        return sessions.count == 1 ? .shown : .queued
    }

    func remove(requestId: String) {
        let before = sessions.count
        sessions.removeAll { $0.requestId == requestId }
        if sessions.count != before { save() }
    }

    func remove(sessionId: String) {
        let before = sessions.count
        sessions.removeAll { $0.sessionId == sessionId }
        if sessions.count != before { save() }
    }

    func setStatus(_ status: AgentStatus, requestId: String) {
        guard let index = sessions.firstIndex(where: { $0.requestId == requestId }) else { return }
        sessions[index].status = status
    }

    /// Drops sessions whose hook helper has exited (it timed out, or the
    /// user answered in the terminal) and returns them. A session with no
    /// helper id (a link request) expires `maxAge` seconds after it arrived.
    @discardableResult
    func pruneDeadProcesses(isAlive: (Int32) -> Bool, now: Date = Date(), maxAge: TimeInterval = 3600) -> [AgentSession] {
        let dead = sessions.filter { session in
            guard let pid = session.hookPid else { return now.timeIntervalSince(session.receivedAt) > maxAge }
            return !isAlive(pid)
        }
        guard !dead.isEmpty else { return [] }
        let ids = Set(dead.map(\.requestId))
        sessions.removeAll { ids.contains($0.requestId) }
        save()
        return dead
    }

    /// Turns bypass on for `sessionId`, or off (`nil`).
    func setBypassed(sessionId: String, bypass: AgentBypass?) {
        bypassed[sessionId] = bypass
        save()
    }

    /// Ends every bypass whose CLI process has exited and returns the
    /// session ids.
    @discardableResult
    func pruneBypass(isAlive: (Int32) -> Bool) -> [String] {
        let ended = bypassed.filter { !isAlive($0.value.cliPid) }.map(\.key).sorted()
        guard !ended.isEmpty else { return [] }
        for id in ended { bypassed[id] = nil }
        save()
        return ended
    }

    func removeAll() {
        sessions.removeAll()
        save()
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var sessions: [AgentSession]
        var bypassed: [String: AgentBypass]
    }

    func save() {
        guard let fileURL else { return }
        let snapshot = Snapshot(sessions: sessions, bypassed: bypassed)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? AgentHookPaths.writeAtomically(data, to: fileURL)
    }

    /// Reloads the saved queue, keeping only sessions whose helper still
    /// runs and bypasses whose CLI still runs.
    func load(isAlive: (Int32) -> Bool) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        sessions = snapshot.sessions.filter { session in
            guard let pid = session.hookPid else { return false }
            return isAlive(pid)
        }
        bypassed = snapshot.bypassed.filter { isAlive($0.value.cliPid) }
        for index in sessions.indices where sessions[index].status == .sending {
            sessions[index].status = AgentSession.status(for: sessions[index].event)
        }
        save()
    }
}
