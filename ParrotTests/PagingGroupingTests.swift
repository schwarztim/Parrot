import XCTest

@testable import Parrot

/// History paging (100 rows, then pages of 300), day grouping, select all
/// matching, bulk delete and the combined copy text.
@MainActor
final class PagingGroupingTests: XCTestCase {

    private var dbURL: URL!
    private var store: HistoryStore!

    override func setUp() async throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-paging-\(UUID().uuidString).db")
        store = try HistoryStore(databaseURL: dbURL)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    /// `count` rows one hour apart, newest last inserted; every third
    /// mentions "apple".
    private func seed(_ count: Int, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
        let records = (0..<count).map { i in
            HistoryRecord(
                timestamp: start.addingTimeInterval(Double(i) * 3600),
                rawTranscript: i % 3 == 0 ? "apple note \(i)" : "plain note \(i)",
                finalText: "Note \(i)",
                sourceKey: "parrot:\(1_700_000_000 + i * 3600)"
            )
        }
        try store.importRecords(records)
    }

    func testPagingRules() {
        XCTAssertEqual(HistoryPaging.limit(forOffset: 0), 100)
        XCTAssertEqual(HistoryPaging.limit(forOffset: 100), 300)
        XCTAssertEqual(HistoryPaging.limit(forOffset: 400), 300)
        XCTAssertTrue(HistoryPaging.hasMore(lastPageCount: 100, requested: 100))
        XCTAssertFalse(HistoryPaging.hasMore(lastPageCount: 42, requested: 300))
    }

    func testModelPagesHundredThenThreeHundred() throws {
        try seed(450)
        let model = HistoryListModel(store: store)

        model.reload()
        XCTAssertEqual(model.entries.count, 100)
        XCTAssertEqual(model.totalCount, 450)
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.entries.first?.finalText, "Note 449", "newest first")

        model.loadMore()
        XCTAssertEqual(model.entries.count, 400)
        XCTAssertTrue(model.hasMore)

        model.loadMore()
        XCTAssertEqual(model.entries.count, 450)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(Set(model.entries.map(\.id)).count, 450, "no duplicates across pages")
        XCTAssertEqual(model.entries.last?.finalText, "Note 0")
    }

    func testLoadMoreIfNeededTriggersNearTheEnd() throws {
        try seed(150)
        let model = HistoryListModel(store: store)
        model.reload()
        model.loadMoreIfNeeded(after: model.entries[10])
        XCTAssertEqual(model.entries.count, 100)
        model.loadMoreIfNeeded(after: model.entries[95])
        XCTAssertEqual(model.entries.count, 150)
    }

    func testGroupsByCalendarDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_700_006_400) // 2023-11-15 00:00 UTC
        let entries = [
            HistoryEntry(id: 3, timestamp: day.addingTimeInterval(86_400 + 60), rawTranscript: "", finalText: "c", appBundleID: nil, modeName: nil),
            HistoryEntry(id: 2, timestamp: day.addingTimeInterval(3600), rawTranscript: "", finalText: "b", appBundleID: nil, modeName: nil),
            HistoryEntry(id: 1, timestamp: day.addingTimeInterval(60), rawTranscript: "", finalText: "a", appBundleID: nil, modeName: nil),
        ]
        let groups = HistoryGrouping.byDay(entries, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries.map(\.id), [3])
        XCTAssertEqual(groups[1].entries.map(\.id), [2, 1])
        XCTAssertEqual(groups[1].day, day)
    }

    func testDayTitles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_049_600) // Wed 2023-11-15 12:00 UTC
        XCTAssertEqual(HistoryGrouping.title(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(HistoryGrouping.title(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(HistoryGrouping.title(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar), "Sunday")
        XCTAssertEqual(HistoryGrouping.title(for: now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar), "October 11, 2022")
    }

    func testSelectAllMatchingTargetsEveryMatch() throws {
        try seed(450)
        let model = HistoryListModel(store: store)
        model.query = "apple"
        model.reload()
        XCTAssertEqual(model.totalCount, 150)
        XCTAssertEqual(model.entries.count, 100)

        model.selectAllMatching()
        XCTAssertEqual(model.selectionCount, 150, "counts the full match, not the loaded page")
        XCTAssertEqual(model.selectedEntries().count, 150)

        let result = model.deleteSelection()
        XCTAssertEqual(result.count, 150)
        XCTAssertEqual(try store.count(), 300)
        XCTAssertEqual(try store.count(matching: "apple"), 0)
        XCTAssertEqual(try store.ledgerRows().count, 450, "stats survive the bulk delete")
    }

    func testChangingSearchLeavesSelectAll() throws {
        try seed(30)
        let model = HistoryListModel(store: store)
        model.reload()
        model.selectAllMatching()
        model.query = "apple"
        model.reload()
        XCTAssertFalse(model.isSelectAllMode)
    }

    func testCheckedDeleteAndCopyText() throws {
        try seed(5)
        let model = HistoryListModel(store: store)
        model.reload()
        model.isMultiSelect = true
        model.toggleChecked(model.entries[0].id)
        model.toggleChecked(model.entries[1].id)
        XCTAssertEqual(model.selectionCount, 2)

        let utc = TimeZone(identifier: "UTC")!
        let text = HistoryGrouping.copyText(for: model.selectedEntries(), timeZone: utc)
        XCTAssertEqual(text, "Nov 15, 2023 at 1:13 AM\nNote 3\n\nNov 15, 2023 at 2:13 AM\nNote 4")

        model.deleteSelection()
        XCTAssertEqual(try store.count(), 3)
        XCTAssertFalse(model.isMultiSelect)
    }

    func testDurationAndDetailFormats() {
        XCTAssertEqual(HistoryGrouping.durationText(7), "0:07")
        XCTAssertEqual(HistoryGrouping.durationText(765), "12:45")
        XCTAssertEqual(HistoryGrouping.durationText(3723), "1:02:03")
        XCTAssertEqual(HistoryGrouping.secondsText(0.85), "850 ms")
        XCTAssertEqual(HistoryGrouping.secondsText(2.34), "2.3 s")
        XCTAssertEqual(HistoryGrouping.detailDate(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!), "Jan 1, 1970 at 12:00 AM")
    }

    func testSpeakerTurnsMergeConsecutiveSegments() {
        let segments = [
            TranscriptSegment(text: "hi", start: 0, end: 1, speaker: "A"),
            TranscriptSegment(text: "there", start: 1, end: 2, speaker: "A"),
            TranscriptSegment(text: "hello", start: 2, end: 3, speaker: "B"),
        ]
        let turns = RecordingDetails.speakerTurns(segments)
        XCTAssertEqual(turns.map(\.text), ["hi there", "hello"])
        XCTAssertEqual(turns.first?.end, 2)
    }
}
