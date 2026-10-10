import Foundation

/// The stats panel's range.
enum StatsRange: String, CaseIterable, Identifiable {
    case week
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "This week"
        case .allTime: return "All time"
        }
    }

    var savedLabel: String {
        switch self {
        case .week: return "Saved this week"
        case .allTime: return "Saved all time"
        }
    }
}

/// Pure stats math for Home, the share card and the typing test. [UI]
///
/// Time saved is computed here from words, speaking time and the user's
/// typing speed (`GeneralSettings.typingWPM`), so the tile follows the
/// typing test at once.
enum StatsMath {

    /// The "average typer" the share card compares against.
    static let averageTypingWPM: Double = 40

    /// Seconds saved by speaking `words` in `speakingSeconds` instead of
    /// typing them at `typingWPM`. Never negative.
    static func timeSaved(words: Int, speakingSeconds: TimeInterval, typingWPM: Double) -> TimeInterval {
        guard words > 0, typingWPM > 0 else { return 0 }
        let typingSeconds = Double(words) / typingWPM * 60
        return max(0, typingSeconds - max(0, speakingSeconds))
    }

    /// Words per minute spoken, or 0 without speaking time.
    static func speakingWPM(words: Int, seconds: TimeInterval) -> Double {
        guard words > 0, seconds > 0 else { return 0 }
        return Double(words) / (seconds / 60)
    }

    /// The WPM to show: the service's figure when it has one, else derived.
    static func displayWPM(_ snapshot: StatsSnapshot) -> Double {
        snapshot.wordsPerMinute > 0 ? snapshot.wordsPerMinute : speakingWPM(words: snapshot.wordCount, seconds: snapshot.duration)
    }

    /// How much faster speaking is than typing, in whole percent (0 when
    /// slower or unknown).
    static func percentFaster(speakingWPM: Double, typingWPM: Double) -> Int {
        guard speakingWPM > 0, typingWPM > 0 else { return 0 }
        return max(0, Int(((speakingWPM / typingWPM - 1) * 100).rounded()))
    }

    /// Start of the range (the current week's first day), or nil for all time.
    static func rangeStart(_ range: StatsRange, now: Date, calendar: Calendar = .current) -> Date? {
        switch range {
        case .allTime: return nil
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        }
    }

    /// "45s", "12m", "1h 5m".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "1,234" in the user's locale.
    static func countText(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// The most used mode tile: the mode's name, or "None" before any
    /// dictation recorded one.
    static func modeText(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "None" : trimmed
    }

    /// Deterministic bar heights (0.15...1) for the share card's waveform
    /// art: the same stats always draw the same fingerprint.
    static func fingerprint(seed: Int, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<count).map { index in
            // xorshift64
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let noise = Double(state % 1000) / 1000
            // A gentle hump so the art reads as a waveform.
            let position = Double(index) / Double(max(1, count - 1))
            let envelope = 0.45 + 0.55 * sin(position * .pi)
            return min(1, max(0.15, noise * envelope + 0.15))
        }
    }
}
