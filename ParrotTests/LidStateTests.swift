import XCTest

@testable import Parrot

/// A manual clock for AUD tests: scheduled work runs only on `advance`.
@MainActor
final class AudioTestScheduler: DelayScheduler {
    private struct Item {
        let due: TimeInterval
        let order: Int
        let work: @MainActor () -> Void
        let handle: ScheduledWork
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var counter = 0

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let handle = ScheduledWork()
        items.append(Item(due: now + max(delay, 0), order: counter, work: work, handle: handle))
        counter += 1
        return handle
    }

    /// Runs everything due within `seconds`, in time order, including work
    /// scheduled by the work it runs.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = items
            .filter({ !$0.handle.isCancelled && $0.due <= end + 1e-9 })
            .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            items.removeAll { $0.order == next.order }
            now = max(now, next.due)
            next.work()
        }
        now = end
        items.removeAll { $0.handle.isCancelled }
    }

    var pendingCount: Int { items.filter { !$0.handle.isCancelled }.count }
}

@MainActor
final class LidStateTests: XCTestCase {

    private let builtInActive = DisplayInfo(isBuiltIn: true, isActive: true, isMirroring: false)
    private let externalActive = DisplayInfo(isBuiltIn: false, isActive: true, isMirroring: false)

    func testOpenLidWithBuiltInDisplayActive() {
        XCTAssertFalse(LidState.isClosed(displays: [builtInActive]))
        XCTAssertFalse(LidState.isClosed(displays: [builtInActive, externalActive]))
    }

    func testClosedWhenOnlyExternalDisplaysAreActive() {
        XCTAssertTrue(LidState.isClosed(displays: [externalActive]))
        let builtInAsleep = DisplayInfo(isBuiltIn: true, isActive: false, isMirroring: false)
        XCTAssertTrue(LidState.isClosed(displays: [builtInAsleep, externalActive]))
    }

    func testMirroredBuiltInDisplayIsNotAClosedLid() {
        let mirrored = DisplayInfo(isBuiltIn: true, isActive: false, isMirroring: true)
        XCTAssertFalse(LidState.isClosed(displays: [mirrored, externalActive]))
    }

    func testNoDisplaysReadsAsOpen() {
        XCTAssertFalse(LidState.isClosed(displays: []))
    }

    func testChangesAreDebouncedByHalfASecond() {
        var displays = [builtInActive, externalActive]
        let scheduler = AudioTestScheduler()
        let monitor = LidStateMonitor(readDisplays: { displays }, scheduler: scheduler)
        var reported: [Bool] = []
        monitor.onChange = { reported.append($0) }
        XCTAssertFalse(monitor.isLidClosed)

        displays = [externalActive]
        monitor.displaysChanged()
        scheduler.advance(by: 0.3)
        monitor.displaysChanged() // a second event restarts the wait
        scheduler.advance(by: 0.3)
        XCTAssertEqual(reported, [], "nothing reported before 0.5 s of quiet")
        XCTAssertFalse(monitor.isLidClosed)

        scheduler.advance(by: 0.25)
        XCTAssertEqual(reported, [true])
        XCTAssertTrue(monitor.isLidClosed)
    }

    func testNoReportWhenTheStateDidNotChange() {
        let scheduler = AudioTestScheduler()
        let monitor = LidStateMonitor(readDisplays: { [self] in [builtInActive] }, scheduler: scheduler)
        var reported: [Bool] = []
        monitor.onChange = { reported.append($0) }

        monitor.displaysChanged()
        scheduler.advance(by: 1)
        XCTAssertEqual(reported, [])
    }

    func testReopeningReportsOpen() {
        var displays = [externalActive]
        let scheduler = AudioTestScheduler()
        let monitor = LidStateMonitor(readDisplays: { displays }, scheduler: scheduler)
        var reported: [Bool] = []
        monitor.onChange = { reported.append($0) }
        XCTAssertTrue(monitor.isLidClosed)

        displays = [builtInActive, externalActive]
        monitor.displaysChanged()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(reported, [false])
    }
}
