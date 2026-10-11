import Foundation

/// Runs work on the main actor after a delay. Production sleeps a task;
/// tests pass a manual clock so restores fire on demand. [OUT]
@MainActor
protocol DelayScheduler: AnyObject {
    /// Schedules `work` to run `delay` seconds from now. Cancel the returned
    /// handle to drop it.
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork
}

/// A pending piece of scheduled work.
@MainActor
final class ScheduledWork {
    private let onCancel: @MainActor () -> Void
    private(set) var isCancelled = false

    init(onCancel: @escaping @MainActor () -> Void = {}) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }
}

/// The production scheduler: a main-actor task that sleeps, then runs.
@MainActor
final class TaskDelayScheduler: DelayScheduler {
    init() {}

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let task = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            work()
        }
        return ScheduledWork { task.cancel() }
    }
}
