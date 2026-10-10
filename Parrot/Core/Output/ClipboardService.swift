import Foundation

// MARK: - ClipboardBehaviour

/// What the clipboard holds after a dictation is pasted. [OUT]
enum ClipboardBehaviour: String, CaseIterable, Identifiable, Sendable {
    /// Put back what the user had copied (the default).
    case keep
    /// Leave the dictation on the clipboard.
    case replace

    var id: String { rawValue }

    /// Maps Superwhisper's stored `clipboardBehaviour` values for the
    /// importer: `bypass` keeps the user's clipboard, `default` replaces it.
    init?(superwhisperValue: String) {
        switch superwhisperValue {
        case "bypass": self = .keep
        case "default": self = .replace
        default: return nil
        }
    }
}

// MARK: - ClipboardService

/// Puts a dictation on the clipboard and, when asked, puts the user's own
/// clipboard back afterwards. [OUT]
///
/// `write` snapshots every item and type first. `finish` schedules the
/// restore. A newer write cancels a pending restore and inherits its
/// snapshot, so back-to-back dictations still end with the user's original
/// clipboard. A restore is skipped when the clipboard could not be read, or
/// when someone else changed it after the dictation was written.
@MainActor
final class ClipboardService {

    /// One dictation's turn on the clipboard.
    struct Ticket {
        /// What to put back; nil when the clipboard could not be read.
        let snapshot: PasteboardSnapshot?
        /// `changeCount` right after the dictation was written.
        let changeCount: Int
        let generation: Int
    }

    private let pasteboard: PasteboardAccess
    private let scheduler: DelayScheduler
    private var generation = 0
    private var pending: (work: ScheduledWork, ticket: Ticket)?

    init(pasteboard: PasteboardAccess, scheduler: DelayScheduler) {
        self.pasteboard = pasteboard
        self.scheduler = scheduler
    }

    /// True while a restore is waiting to run.
    var hasPendingRestore: Bool { pending != nil }

    /// Snapshots the clipboard, then writes `text`. Marks it `transient` so
    /// clipboard history apps skip it.
    @discardableResult
    func write(_ text: String, transient: Bool) -> Ticket {
        let snapshot: PasteboardSnapshot?
        if let pending, pasteboard.changeCount == pending.ticket.changeCount {
            // The clipboard still holds our earlier dictation: the user's
            // own contents are in that pending snapshot.
            snapshot = pending.ticket.snapshot
        } else {
            snapshot = pasteboard.snapshot()
        }
        pending?.work.cancel()
        pending = nil

        pasteboard.writeText(text, transient: transient)
        generation += 1
        return Ticket(snapshot: snapshot, changeCount: pasteboard.changeCount, generation: generation)
    }

    /// Puts the ticket's snapshot back after `delay` seconds. A nil delay
    /// leaves the dictation on the clipboard.
    func finish(_ ticket: Ticket, restoreAfter delay: TimeInterval?) {
        guard let delay else { return }
        guard ticket.generation == generation else { return }
        guard ticket.snapshot != nil else {
            diagLog("[Parrot:Output] Skipping clipboard restore: the original contents were unavailable")
            return
        }
        let work = scheduler.schedule(after: max(0, delay)) { [weak self] in
            self?.restore(ticket)
        }
        pending = (work, ticket)
    }

    private func restore(_ ticket: Ticket) {
        guard pending?.ticket.generation == ticket.generation else { return }
        pending = nil
        guard pasteboard.changeCount == ticket.changeCount else {
            diagLog("[Parrot:Output] Skipping clipboard restore: the clipboard changed after the paste")
            return
        }
        guard let snapshot = ticket.snapshot else { return }
        pasteboard.restore(snapshot)
    }
}
