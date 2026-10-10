import XCTest

@testable import Parrot

// MARK: - Fakes shared by the OUT tests

/// An in-memory pasteboard. Every write bumps `changeCount`, like the real one.
@MainActor
final class FakePasteboard: PasteboardAccess {
    static let plainText = "public.utf8-plain-text"

    var changeCount = 0
    var items: [PasteboardItemSnapshot] = []
    /// False makes `snapshot()` fail, as when the pasteboard cannot be read.
    var readable = true

    func snapshot() -> PasteboardSnapshot? {
        readable ? PasteboardSnapshot(items: items) : nil
    }

    func writeText(_ text: String, transient: Bool) {
        var entries = [PasteboardItemSnapshot.Entry(type: Self.plainText, data: Data(text.utf8))]
        if transient {
            entries.append(.init(type: PasteboardMarker.transient, data: Data()))
            entries.append(.init(type: PasteboardMarker.concealed, data: Data()))
        }
        items = [PasteboardItemSnapshot(entries: entries)]
        changeCount += 1
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        items = snapshot.items
        changeCount += 1
    }

    /// Another app copies something.
    func externalCopy(_ text: String) {
        items = [PasteboardItemSnapshot(entries: [.init(type: Self.plainText, data: Data(text.utf8))])]
        changeCount += 1
    }

    var text: String? {
        items.first?.entries.first { $0.type == Self.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
    }

    var types: [String] {
        items.flatMap { $0.entries.map(\.type) }
    }
}

/// A clock that runs scheduled work only when told to.
@MainActor
final class ManualScheduler: DelayScheduler {
    private var queue: [(delay: TimeInterval, handle: ScheduledWork, work: @MainActor () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let handle = ScheduledWork()
        queue.append((delay, handle, work))
        return handle
    }

    /// Delays of scheduled work that is still live.
    var activeDelays: [TimeInterval] {
        queue.filter { !$0.handle.isCancelled }.map(\.delay)
    }

    /// Runs every live item, in order.
    func runAll() {
        let items = queue
        queue = []
        for item in items where !item.handle.isCancelled {
            item.work()
        }
    }
}

// MARK: - ClipboardRestoreTests

@MainActor
final class ClipboardRestoreTests: XCTestCase {

    private var pasteboard: FakePasteboard!
    private var scheduler: ManualScheduler!
    private var clipboard: ClipboardService!

    /// The user's clipboard: one item with two types (text and an image).
    private let userItems = [
        PasteboardItemSnapshot(entries: [
            .init(type: FakePasteboard.plainText, data: Data("mine".utf8)),
            .init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        ]),
    ]

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
        pasteboard.items = userItems
        scheduler = ManualScheduler()
        clipboard = ClipboardService(pasteboard: pasteboard, scheduler: scheduler)
    }

    func testRestoresEveryItemAndTypeAfterTheDelay() {
        let ticket = clipboard.write("dictation", transient: true)
        XCTAssertEqual(pasteboard.text, "dictation")

        clipboard.finish(ticket, restoreAfter: 1.0)
        XCTAssertEqual(scheduler.activeDelays, [1.0])
        XCTAssertEqual(pasteboard.text, "dictation", "nothing goes back before the delay")

        scheduler.runAll()
        XCTAssertEqual(pasteboard.items, userItems)
        XCTAssertFalse(clipboard.hasPendingRestore)
    }

    func testNewerPasteCancelsPendingRestoreAndKeepsTheOriginal() {
        let first = clipboard.write("first", transient: true)
        clipboard.finish(first, restoreAfter: 1.0)

        let second = clipboard.write("second", transient: true)
        XCTAssertEqual(scheduler.activeDelays, [], "the first restore is cancelled")
        XCTAssertEqual(pasteboard.text, "second")

        clipboard.finish(second, restoreAfter: 1.0)
        scheduler.runAll()
        XCTAssertEqual(pasteboard.items, userItems, "the user's clipboard, not the first dictation")
    }

    func testStaleTicketDoesNotScheduleARestore() {
        let first = clipboard.write("first", transient: true)
        _ = clipboard.write("second", transient: true)
        clipboard.finish(first, restoreAfter: 1.0)
        XCTAssertEqual(scheduler.activeDelays, [])
    }

    func testSkipsRestoreWhenTheClipboardCouldNotBeRead() {
        pasteboard.readable = false
        let ticket = clipboard.write("dictation", transient: true)
        clipboard.finish(ticket, restoreAfter: 1.0)

        XCTAssertEqual(scheduler.activeDelays, [])
        XCTAssertEqual(pasteboard.text, "dictation")
    }

    func testNilDelayLeavesTheDictation() {
        let ticket = clipboard.write("dictation", transient: true)
        clipboard.finish(ticket, restoreAfter: nil)

        XCTAssertEqual(scheduler.activeDelays, [])
        XCTAssertEqual(pasteboard.text, "dictation")
    }

    func testAnEmptyClipboardIsEmptyAgainAfterRestore() {
        pasteboard.items = []
        let ticket = clipboard.write("dictation", transient: true)
        clipboard.finish(ticket, restoreAfter: 1.0)
        scheduler.runAll()

        XCTAssertEqual(pasteboard.items, [])
    }

    func testCopyDuringTheDelayIsNotOverwritten() {
        let ticket = clipboard.write("dictation", transient: true)
        clipboard.finish(ticket, restoreAfter: 1.0)
        pasteboard.externalCopy("copied meanwhile")
        scheduler.runAll()

        XCTAssertEqual(pasteboard.text, "copied meanwhile")
    }

    func testFreshSnapshotAfterTheRestoreRan() {
        let first = clipboard.write("first", transient: true)
        clipboard.finish(first, restoreAfter: 1.0)
        scheduler.runAll()
        pasteboard.externalCopy("newer copy")

        let second = clipboard.write("second", transient: true)
        clipboard.finish(second, restoreAfter: 1.0)
        scheduler.runAll()
        XCTAssertEqual(pasteboard.text, "newer copy")
    }

    func testTransientMarkerOnlyWhenHistoryIsOff() {
        clipboard.write("hidden", transient: true)
        XCTAssertTrue(pasteboard.types.contains(PasteboardMarker.transient))
        XCTAssertTrue(pasteboard.types.contains(PasteboardMarker.concealed))

        clipboard.write("kept", transient: false)
        XCTAssertFalse(pasteboard.types.contains(PasteboardMarker.transient))
        XCTAssertFalse(pasteboard.types.contains(PasteboardMarker.concealed))
    }

    func testClipboardBehaviourRawValuesAndSuperwhisperMapping() {
        XCTAssertEqual(ClipboardBehaviour.keep.rawValue, "keep")
        XCTAssertEqual(ClipboardBehaviour.replace.rawValue, "replace")
        XCTAssertEqual(ClipboardBehaviour(superwhisperValue: "bypass"), .keep)
        XCTAssertEqual(ClipboardBehaviour(superwhisperValue: "default"), .replace)
        XCTAssertNil(ClipboardBehaviour(superwhisperValue: "other"))
    }
}

// MARK: - AlertMuterTests

@MainActor
final class AlertMuterTests: XCTestCase {

    private final class FakeVolume: AlertVolumeControl {
        var volume: Int?
        var reads = 0
        var writes: [Int] = []

        init(volume: Int?) { self.volume = volume }

        func read() -> Int? {
            reads += 1
            return volume
        }

        func set(_ volume: Int) {
            writes.append(volume)
            self.volume = volume
        }
    }

    func testMutesThenRestoresTheOriginalVolume() {
        let volume = FakeVolume(volume: 70)
        let scheduler = ManualScheduler()
        let muter = AlertMuter(control: volume, scheduler: scheduler)

        muter.muteBriefly(for: 0.6)
        XCTAssertEqual(volume.volume, 0)
        XCTAssertTrue(muter.isMuted)

        scheduler.runAll()
        XCTAssertEqual(volume.volume, 70)
        XCTAssertFalse(muter.isMuted)
    }

    func testOverlappingMutesReadTheVolumeOnce() {
        let volume = FakeVolume(volume: 40)
        let scheduler = ManualScheduler()
        let muter = AlertMuter(control: volume, scheduler: scheduler)

        muter.muteBriefly()
        muter.muteBriefly()
        XCTAssertEqual(volume.reads, 1)
        XCTAssertEqual(scheduler.activeDelays.count, 1, "the second mute extends the first")

        scheduler.runAll()
        XCTAssertEqual(volume.writes, [0, 40])
    }

    func testSilentOrUnreadableVolumeIsLeftAlone() {
        let silent = FakeVolume(volume: 0)
        AlertMuter(control: silent, scheduler: ManualScheduler()).muteBriefly()
        XCTAssertEqual(silent.writes, [])

        let unreadable = FakeVolume(volume: nil)
        AlertMuter(control: unreadable, scheduler: ManualScheduler()).muteBriefly()
        XCTAssertEqual(unreadable.writes, [])
    }
}
