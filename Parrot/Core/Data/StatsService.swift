import Foundation

/// Usage totals derived from history. [DATA]
struct StatsSnapshot: Equatable, Sendable {
    var dictationCount: Int = 0
    var wordCount: Int = 0
    /// Total speaking time in seconds.
    var duration: TimeInterval = 0
    var wordsPerMinute: Double = 0
    /// Typing time minus speaking time, in seconds.
    var timeSaved: TimeInterval = 0
    /// Distinct apps dictated into.
    var appsUsed: Int = 0
    /// The mode used most often, when any was recorded.
    var mostUsedMode: String? = nil

    static let zero = StatsSnapshot()
}

/// Usage stats for Home and the stats panel. [DATA]
///
/// The DATA workstream supplies the real implementation and assigns it to
/// `AppServices.stats`; UI codes against this protocol.
@MainActor
protocol StatsService: AnyObject {
    /// Totals for dictations since `since`, or all time when nil.
    func snapshot(since: Date?) -> StatsSnapshot
}

/// Placeholder that reports nothing.
@MainActor
final class ZeroStatsService: StatsService {
    init() {}

    func snapshot(since: Date?) -> StatsSnapshot { .zero }
}

/// Stats from the history's ledger, which keeps rows for deleted
/// recordings. File transcriptions are excluded. RecordingStore assigns it
/// to `AppServices.stats` at launch.
@MainActor
final class HistoryStatsService: StatsService {

    private let history: HistoryStore?
    /// Words per minute the user types, read on every snapshot.
    var typingWPM: () -> Double = { HistorySettings.defaultTypingWPM }

    init(history: HistoryStore?) {
        self.history = history
    }

    func snapshot(since: Date?) -> StatsSnapshot {
        let rows = (try? history?.ledgerRows(since: since)) ?? []
        return StatsCalculator.snapshot(rows: rows, typingWPM: typingWPM())
    }
}

/// The stats math, pure for tests.
enum StatsCalculator {

    /// - File transcriptions never count.
    /// - Words per minute and time saved use only rows with both words and
    ///   duration; time saved per row never goes negative.
    static func snapshot(rows: [HistoryStore.LedgerRow], typingWPM: Double) -> StatsSnapshot {
        let counted = rows.filter { !$0.fromFile }
        var snapshot = StatsSnapshot()
        snapshot.dictationCount = counted.count
        snapshot.wordCount = counted.reduce(0) { $0 + $1.wordCount }
        snapshot.duration = counted.reduce(0) { $0 + $1.duration }

        let timed = counted.filter { $0.duration > 0 && $0.wordCount > 0 }
        let timedWords = timed.reduce(0) { $0 + $1.wordCount }
        let timedSeconds = timed.reduce(0) { $0 + $1.duration }
        if timedSeconds > 0 {
            snapshot.wordsPerMinute = Double(timedWords) / (timedSeconds / 60)
        }
        if typingWPM > 0 {
            snapshot.timeSaved = timed.reduce(0) { total, row in
                total + max(0, Double(row.wordCount) / typingWPM * 60 - row.duration)
            }
        }

        let apps = counted.compactMap { row -> String? in
            let id = (row.appBundleID ?? row.appName)?.trimmingCharacters(in: .whitespaces).lowercased()
            return (id?.isEmpty ?? true) ? nil : id
        }
        snapshot.appsUsed = Set(apps).count

        var modeCounts: [String: Int] = [:]
        for row in counted {
            if let mode = row.modeName, !mode.isEmpty { modeCounts[mode, default: 0] += 1 }
        }
        snapshot.mostUsedMode = modeCounts.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }?.key
        return snapshot
    }
}
