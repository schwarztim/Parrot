import Foundation
import Observation

/// State behind the History tab: search, paging (100 then 300), day
/// groups, selection, select all matching, and deletes. [DATA]
@MainActor
@Observable
final class HistoryListModel {

    var store: HistoryStore?

    /// The search text. Call `reload()` after changing it (the view debounces).
    var query = ""
    private(set) var entries: [HistoryEntry] = []
    private(set) var groups: [HistoryDayGroup] = []
    /// Rows matching the current search (or all rows).
    private(set) var totalCount = 0
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// The query the loaded rows belong to.
    private(set) var loadedQuery = ""

    /// The recording shown in the detail pane.
    var selectedID: Int64?
    /// Checked rows in multi-select.
    var checked: Set<Int64> = []
    var isMultiSelect = false {
        didSet {
            if !isMultiSelect { clearSelection() }
        }
    }
    /// "Select all" applies to every recording matching `selectAllQuery`,
    /// not just the loaded pages.
    private(set) var isSelectAllMode = false
    private(set) var selectAllQuery = ""
    private(set) var selectAllCount = 0

    init(store: HistoryStore? = nil) {
        self.store = store
    }

    var selectedEntry: HistoryEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    /// How many recordings a bulk action would touch.
    var selectionCount: Int { isSelectAllMode ? selectAllCount : checked.count }

    // MARK: - Loading

    /// Loads the first page for the current query.
    func reload() {
        guard let store else {
            entries = []
            groups = []
            totalCount = 0
            hasMore = false
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = HistoryPaging.limit(forOffset: 0)
        let page = (try? store.entries(matching: q, limit: limit, offset: 0)) ?? []
        entries = page
        loadedQuery = q
        hasMore = HistoryPaging.hasMore(lastPageCount: page.count, requested: limit)
        totalCount = (try? store.count(matching: q)) ?? page.count
        groups = HistoryGrouping.byDay(entries)
        if let selectedID, !entries.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        checked = checked.intersection(Set(entries.map(\.id)))
        if isSelectAllMode && selectAllQuery != q {
            // A new search changes the target set: leave select-all.
            isSelectAllMode = false
        }
    }

    /// Loads the next page (300 rows).
    func loadMore() {
        guard let store, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let limit = HistoryPaging.limit(forOffset: entries.count)
        let page = (try? store.entries(matching: loadedQuery, limit: limit, offset: entries.count)) ?? []
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: page.filter { !known.contains($0.id) })
        hasMore = HistoryPaging.hasMore(lastPageCount: page.count, requested: limit)
        groups = HistoryGrouping.byDay(entries)
        if isSelectAllMode { checked.formUnion(page.map(\.id)) }
    }

    /// Loads more when `entry` is among the last rows shown.
    func loadMoreIfNeeded(after entry: HistoryEntry) {
        guard hasMore, let index = entries.lastIndex(where: { $0.id == entry.id }) else { return }
        if index >= entries.count - 20 { loadMore() }
    }

    // MARK: - Selection

    func toggleChecked(_ id: Int64) {
        if isSelectAllMode {
            isSelectAllMode = false
        }
        if checked.contains(id) {
            checked.remove(id)
        } else {
            checked.insert(id)
        }
    }

    /// Selects every recording matching the current search.
    func selectAllMatching() {
        isMultiSelect = true
        isSelectAllMode = true
        selectAllQuery = loadedQuery
        selectAllCount = totalCount
        checked = Set(entries.map(\.id))
    }

    func clearSelection() {
        checked = []
        isSelectAllMode = false
        selectAllQuery = ""
        selectAllCount = 0
    }

    /// The selected recordings, oldest first. In select-all mode this
    /// fetches every match, not just the loaded pages.
    func selectedEntries() -> [HistoryEntry] {
        if isSelectAllMode, let store {
            return ((try? store.entries(matching: selectAllQuery, limit: Int(Int32.max), offset: 0)) ?? [])
                .sorted { $0.timestamp < $1.timestamp }
        }
        return entries.filter { checked.contains($0.id) }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Delete

    /// Deletes the checked recordings (or every match in select-all mode)
    /// with their folders where Parrot owns them. Returns the ids removed
    /// from the loaded rows and how many rows went.
    @discardableResult
    func deleteSelection() -> (ids: Set<Int64>, count: Int) {
        guard let store else { return ([], 0) }
        let ids: Set<Int64>
        let count: Int
        if isSelectAllMode {
            ids = Set(entries.map(\.id))
            count = (try? store.delete(matching: selectAllQuery)) ?? 0
        } else {
            ids = checked
            count = (try? store.delete(ids: Array(checked))) ?? 0
        }
        clearSelection()
        isMultiSelect = false
        reload()
        return (ids, count)
    }

    func delete(_ entry: HistoryEntry) {
        try? store?.delete(id: entry.id)
        if selectedID == entry.id { selectedID = nil }
        reload()
    }
}
