import AppKit
import CoreGraphics
import Foundation

/// One display as the lid check sees it. [AUD]
struct DisplayInfo: Equatable, Sendable {
    var isBuiltIn: Bool
    var isActive: Bool
    /// Part of a mirror set (a mirrored built-in panel is not in the active list).
    var isMirroring: Bool
}

/// Lid state from the display configuration (au F7). [AUD]
enum LidState {
    /// The lid counts as closed when no built-in display is active. A
    /// built-in display that mirrors another one means mirror mode, not a
    /// closed lid. No displays at all (display sleep) reads as open, so a
    /// sleeping screen never raises the warning.
    static func isClosed(displays: [DisplayInfo]) -> Bool {
        guard !displays.isEmpty else { return false }
        return !displays.contains { $0.isBuiltIn && ($0.isActive || $0.isMirroring) }
    }
}

/// Watches display changes and reports lid open and close, debounced by
/// 0.5 s so a display reconfiguration reports once. [AUD]
@MainActor
final class LidStateMonitor {
    static let debounce: TimeInterval = 0.5

    private(set) var isLidClosed: Bool
    /// Called with the new state after the debounce, only on a change.
    var onChange: (@MainActor (Bool) -> Void)?

    private let readDisplays: @MainActor () -> [DisplayInfo]
    private let scheduler: DelayScheduler
    private var pending: ScheduledWork?
    private var observer: NSObjectProtocol?

    init(
        readDisplays: @escaping @MainActor () -> [DisplayInfo] = LidStateMonitor.currentDisplays,
        scheduler: DelayScheduler? = nil
    ) {
        self.readDisplays = readDisplays
        self.scheduler = scheduler ?? TaskDelayScheduler()
        self.isLidClosed = LidState.isClosed(displays: readDisplays())
    }

    /// Starts listening for display configuration changes.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        diagLog("[Parrot:Audio] Started lid state monitoring via display configuration, lid closed: \(isLidClosed)")
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel()
        pending = nil
    }

    /// A display change arrived; re-check once things settle.
    func displaysChanged() {
        pending?.cancel()
        pending = scheduler.schedule(after: Self.debounce) { [weak self] in
            self?.evaluate()
        }
    }

    private func evaluate() {
        pending = nil
        let closed = LidState.isClosed(displays: readDisplays())
        guard closed != isLidClosed else { return }
        isLidClosed = closed
        diagLog("[Parrot:Audio] Lid state changed: \(closed ? "closed" : "open")")
        onChange?(closed)
    }

    /// Every online display from Core Graphics.
    nonisolated static func currentDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
                isMirroring: CGDisplayIsInMirrorSet(id) != 0
            )
        }
    }
}
