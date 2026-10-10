import XCTest

@testable import Parrot

/// A pasteboard stand-in. Never the real clipboard.
@MainActor
final class FakeClipboardProbe: ClipboardProbe {
    var changeCount = 10
    var types: [String] = []
    var text: String?
    private(set) var stringReads = 0

    func string() -> String? {
        stringReads += 1
        return text
    }

    func copy(_ value: String, types: [String] = ["public.utf8-plain-text"]) {
        changeCount += 1
        text = value
        self.types = types
    }
}

/// Clipboard context counts only a copy made in the 3 seconds before
/// recording, never Parrot's own writes. Uses a fake clock and probe.
@MainActor
final class ClipboardWindowTests: XCTestCase {

    private var probe: FakeClipboardProbe!
    private var watcher: ClipboardWatcher!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        probe = FakeClipboardProbe()
        probe.text = "copied before Parrot started"
        watcher = ClipboardWatcher(probe: probe)
        watcher.now = { [unowned self] in self.clock }
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    func testWhatWasThereAtLaunchNeverCounts() {
        XCTAssertNil(watcher.recentCopy())
        XCTAssertEqual(probe.stringReads, 0, "no copy, no read")
    }

    func testCopyTwoSecondsBeforeCounts() {
        probe.copy("meeting notes")
        watcher.poll()
        advance(2)
        XCTAssertEqual(watcher.recentCopy(), "meeting notes")
    }

    func testCopyExactlyAtTheWindowEdgeCounts() {
        probe.copy("edge")
        watcher.poll()
        advance(3)
        XCTAssertEqual(watcher.recentCopy(), "edge")
    }

    func testCopyFourSecondsBeforeDoesNot() {
        probe.copy("old")
        watcher.poll()
        advance(4)
        XCTAssertNil(watcher.recentCopy())
        XCTAssertEqual(probe.stringReads, 0)
    }

    func testCopyBetweenTicksCountsAtRecordingStart() {
        probe.copy("just now")
        XCTAssertEqual(watcher.recentCopy(), "just now")
    }

    func testTransientAndConcealedWritesNeverCount() {
        probe.copy("Parrot dictation", types: ["public.utf8-plain-text", PasteboardMarker.transient])
        XCTAssertNil(watcher.recentCopy())
        probe.copy("hunter2", types: ["public.utf8-plain-text", PasteboardMarker.concealed])
        XCTAssertNil(watcher.recentCopy())
    }

    func testRestoreAfterPasteDoesNotCount() {
        var pending = true
        watcher.restorePending = { pending }
        probe.copy("Parrot dictation", types: [PasteboardMarker.transient])
        watcher.poll()

        // OUT puts the user's clipboard back and its restore finishes.
        pending = false
        probe.copy("user's original clipboard")
        XCTAssertNil(watcher.recentCopy())
    }

    func testUserCopyWhileARestoreWaitsStillCounts() {
        watcher.restorePending = { true }
        watcher.poll()
        probe.copy("fresh copy")
        XCTAssertEqual(watcher.recentCopy(), "fresh copy")
    }

    func testOwnNonTransientWriteIsDiscarded() {
        let recordingStart = clock
        advance(1)
        probe.copy("dictated text")
        watcher.poll()

        watcher.noteOwnWrite(since: recordingStart)
        advance(0.5)
        XCTAssertNil(watcher.recentCopy())
    }

    func testCopyBeforeTheDictationSurvivesNoteOwnWrite() {
        probe.copy("copied first")
        watcher.poll()
        advance(1)
        watcher.noteOwnWrite(since: clock)
        XCTAssertEqual(watcher.recentCopy(), "copied first")
    }

    func testLaterWriteReplacesTheCopy() {
        probe.copy("user copy")
        watcher.poll()
        probe.copy("Parrot dictation", types: [PasteboardMarker.transient])
        XCTAssertNil(watcher.recentCopy(), "the clipboard no longer holds the user's copy")
    }

    func testBlankCopyDoesNotCount() {
        probe.copy("   \n")
        XCTAssertNil(watcher.recentCopy())
    }
}
