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
    var responseFile: String?
    var cwd: String?
    var project: String?
    var branch: String?
    var title: String?
    var hookPid: Int32?
    var permissionMode: String?
    var permission: HookPermission?
    var questions: [HookQuestion]?
    var receivedAt: Date

    init?(message update: AgentInboxMessage, fullText: String? = nil) {
        guard update.kind == .update, let event = update.event else { return nil }
        agent = update.agent
        sessionId = update.sessionId
        requestId = update.requestId
        self.event = event
        status = AgentSession.status(for: event)
        summary = update.summary ?? ""
        message = fullText ?? update.message ?? ""
        responseFile = update.responseFile
        cwd = update.cwd
        project = update.project
        branch = update.branch
        title = update.title
        hookPid = update.hookPid
        permissionMode = update.permissionMode
        permission = update.permission
        questions = update.questions
        receivedAt = Date(timeIntervalSince1970: update.createdAt)
    }

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
    /// Sessions whose permission requests Parrot approves itself.
    private(set) var bypassed: Set<String> = []

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

    @discardableResult
    func apply(_ message: AgentInboxMessage, fullText: String? = nil) -> Change {
        switch message.kind {
        case .update:
            guard let session = AgentSession(message: message, fullText: fullText) else { return .ignored }
            if let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
                sessions[index] = session
                save()
                return .replaced
            }
            sessions.append(session)
            save()
            return sessions.count == 1 ? .shown : .queued
        case .dismiss:
            // An empty request id means "anything for this session" (the user
            // typed in the terminal). Otherwise only that exact request goes,
            // so a late dismiss never removes a newer request.
            let before = sessions.count
            sessions.removeAll {
                $0.sessionId == message.sessionId && (message.requestId.isEmpty || $0.requestId == message.requestId)
            }
            guard sessions.count != before else { return .ignored }
            save()
            return .removed
        }
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
    /// user answered in the terminal) and returns them.
    @discardableResult
    func pruneDeadProcesses(isAlive: (Int32) -> Bool) -> [AgentSession] {
        let dead = sessions.filter { session in
            guard let pid = session.hookPid else { return true }
            return !isAlive(pid)
        }
        guard !dead.isEmpty else { return [] }
        let ids = Set(dead.map(\.requestId))
        sessions.removeAll { ids.contains($0.requestId) }
        save()
        return dead
    }

    func setBypassed(_ on: Bool, sessionId: String) {
        if on {
            bypassed.insert(sessionId)
        } else {
            bypassed.remove(sessionId)
        }
        save()
    }

    func removeAll() {
        sessions.removeAll()
        save()
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var sessions: [AgentSession]
        var bypassed: [String]
    }

    func save() {
        guard let fileURL else { return }
        let snapshot = Snapshot(sessions: sessions, bypassed: bypassed.sorted())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? AgentHookPaths.writeAtomically(data, to: fileURL)
    }

    /// Reloads the saved queue, keeping only sessions whose helper still runs.
    func load(isAlive: (Int32) -> Bool) {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        sessions = snapshot.sessions.filter { session in
            guard let pid = session.hookPid else { return false }
            return isAlive(pid)
        }
        bypassed = Set(snapshot.bypassed)
        for index in sessions.indices where sessions[index].status == .sending {
            sessions[index].status = AgentSession.status(for: sessions[index].event)
        }
        save()
    }
}
