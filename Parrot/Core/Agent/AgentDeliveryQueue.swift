import Foundation

/// Writes answers to the hook helper's response file, with retries. [AGT]
///
/// A failed write is queued (persisted with its attempts and last error)
/// and retried after a short delay. After the last attempt the entry moves
/// to the failed list and a typed reply goes to the clipboard with a toast,
/// so the user's words are never lost.
@MainActor
final class AgentDeliveryQueue {

    struct Entry: Codable, Equatable {
        var id: UUID
        var requestId: String
        var responseFile: String?
        var response: AgentHookResponse
        var createdAt: Date
        var attempts: Int
        var lastAttempt: Date?
        var lastError: String?
    }

    enum Outcome: Equatable {
        case delivered
        case copiedToClipboard
        case failed
        /// Not sent: the choice is not allowed for this request (see
        /// `AgentBridge.respond`).
        case refused
    }

    private(set) var pending: [Entry] = []
    private(set) var failed: [Entry] = []

    var maxAttempts = 3
    var retryDelay: TimeInterval = 0.4

    /// Writes one response file. Tests replace it.
    var writer: (Data, URL) throws -> Void = { data, url in try AgentHookPaths.writeAtomically(data, to: url) }
    var copyToClipboard: (String) -> Void = { _ in }
    var notify: (String) -> Void = { _ in }
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Response files must sit in this folder; anything else is refused.
    private let responsesDirectory: URL
    private let fileURL: URL?
    private var cancelled: Set<String> = []

    init(responsesDirectory: URL, fileURL: URL? = nil) {
        self.responsesDirectory = responsesDirectory.standardizedFileURL
        self.fileURL = fileURL
        load()
    }

    /// Delivers `response` to `responseFile` (0600). When that is
    /// impossible, `fallbackText` (a reply the user typed or dictated) goes
    /// to the clipboard and the user is told.
    @discardableResult
    func send(_ response: AgentHookResponse, to responseFile: URL?, fallbackText: String?, agentName: String) async -> Outcome {
        cancelled.remove(response.requestId)
        guard let target = allowedTarget(responseFile, requestId: response.requestId) else {
            return fallBack(fallbackText, agentName: agentName)
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(response)
        } catch {
            return fallBack(fallbackText, agentName: agentName)
        }

        var entry = Entry(
            id: UUID(), requestId: response.requestId, responseFile: target.path,
            response: response, createdAt: Date(), attempts: 0
        )
        while entry.attempts < maxAttempts {
            if cancelled.contains(response.requestId) { break }
            entry.attempts += 1
            entry.lastAttempt = Date()
            do {
                try writer(data, target)
                pending.removeAll { $0.id == entry.id }
                save()
                return .delivered
            } catch {
                entry.lastError = error.localizedDescription
                upsertPending(entry)
                if entry.attempts < maxAttempts { await sleep(retryDelay) }
            }
        }
        pending.removeAll { $0.id == entry.id }
        failed.append(entry)
        save()
        return fallBack(fallbackText, agentName: agentName)
    }

    /// Stops retrying `requestId` (its helper has gone away).
    func cancel(requestId: String) {
        cancelled.insert(requestId)
    }

    // MARK: Helpers

    /// `responses/<requestId>.json` and nothing else, checked again here.
    private func allowedTarget(_ file: URL?, requestId: String) -> URL? {
        guard let file, AgentInboxMessage.isValidRequestId(requestId) else { return nil }
        let url = file.standardizedFileURL
        guard url.deletingLastPathComponent().path == responsesDirectory.path,
              url.lastPathComponent == "\(requestId).json"
        else { return nil }
        return url
    }

    private func fallBack(_ text: String?, agentName: String) -> Outcome {
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            copyToClipboard(text)
            notify("Couldn't reach \(agentName). Your reply is on the clipboard.")
            return .copiedToClipboard
        }
        notify("Couldn't reach \(agentName). Answer in the terminal instead.")
        return .failed
    }

    private func upsertPending(_ entry: Entry) {
        if let index = pending.firstIndex(where: { $0.id == entry.id }) {
            pending[index] = entry
        } else {
            pending.append(entry)
        }
        save()
    }

    private struct Snapshot: Codable {
        var pending: [Entry]
        var failed: [Entry]
    }

    private func save() {
        guard let fileURL else { return }
        // Keep the failed list short; it is only for diagnosis.
        let snapshot = Snapshot(pending: pending, failed: Array(failed.suffix(20)))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? AgentHookPaths.writeAtomically(data, to: fileURL)
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        // A pending entry from a previous run has no helper waiting any more.
        failed = snapshot.failed + snapshot.pending
        pending = []
    }
}
