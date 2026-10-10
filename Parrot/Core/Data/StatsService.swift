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
