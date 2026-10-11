import AppKit

// MARK: - ClipboardProbe

/// The few pasteboard reads the watcher needs. The watcher checks the change
/// count and the item types on every tick and reads text only at recording
/// start, so it never pulls large items or other apps' data needlessly.
@MainActor
protocol ClipboardProbe: AnyObject {
    var changeCount: Int { get }
    /// Type identifiers on the pasteboard right now.
    var types: [String] { get }
    /// Plain text on the pasteboard, if any.
    func string() -> String?
}

/// `NSPasteboard.general`.
@MainActor
final class SystemClipboardProbe: ClipboardProbe {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }
    var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }
    func string() -> String? { pasteboard.string(forType: .string) }
}

// MARK: - ClipboardWatcher

/// Tracks when the user last copied something, so clipboard context only
/// uses a copy made in the 3 seconds before recording starts. [LLM]
///
/// A short timer notes each change of the pasteboard's change count. These
/// changes never count as a copy:
/// - items marked transient or concealed (Parrot's own pasted dictation,
///   and password managers),
/// - Parrot putting the user's clipboard back after a paste (a change seen
///   just as OUT's pending restore finishes),
/// - anything `noteOwnWrite(since:)` claims for a finished dictation.
/// What was on the clipboard before Parrot started never counts.
@MainActor
final class ClipboardWatcher {

    /// How recent a copy must be, in seconds before recording starts.
    static let window: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.25

    private let probe: ClipboardProbe
    /// Whether OUT has a clipboard restore waiting (`ClipboardService`).
    var restorePending: () -> Bool = { false }
    /// The clock; tests replace it.
    var now: () -> Date = Date.init

    private var lastChangeCount: Int
    private var lastCopy: (changeCount: Int, at: Date)?
    private var restoreWasPending = false
    private var timer: Timer?

    init(probe: ClipboardProbe? = nil) {
        let probe = probe ?? SystemClipboardProbe()
        self.probe = probe
        self.lastChangeCount = probe.changeCount
    }

    /// Starts the timer. Tests call `poll()` instead.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Notes a change since the last tick.
    func poll() {
        let pending = restorePending()
        defer { restoreWasPending = pending }
        let count = probe.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let types = probe.types
        if types.contains(PasteboardMarker.transient) || types.contains(PasteboardMarker.concealed) { return }
        if restoreWasPending && !pending { return }
        lastCopy = (count, now())
    }

    /// The text the user copied within `window` seconds before now, or nil.
    /// Reads the pasteboard text only when such a copy exists.
    func recentCopy() -> String? {
        poll()
        guard let copy = lastCopy, copy.changeCount == probe.changeCount else { return nil }
        let age = now().timeIntervalSince(copy.at)
        guard age >= 0, age <= Self.window else { return nil }
        guard let text = probe.string(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// A dictation that started at `start` has finished: a copy noted since
    /// then is Parrot's own delivery (clipboard history on, so it carried no
    /// transient marker) or a copy made mid-recording, and never counts.
    func noteOwnWrite(since start: Date) {
        poll()
        if let copy = lastCopy, copy.at >= start {
            lastCopy = nil
        }
    }
}
