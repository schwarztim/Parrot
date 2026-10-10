import Foundation

/// Paging rules for the history list: 100 rows first, then 300 per page.
enum HistoryPaging {
    static let firstPage = 100
    static let nextPage = 300

    /// How many rows to fetch at `offset`.
    static func limit(forOffset offset: Int) -> Int {
        offset == 0 ? firstPage : nextPage
    }

    /// More rows remain when the last page came back full.
    static func hasMore(lastPageCount: Int, requested: Int) -> Bool {
        lastPageCount >= requested
    }
}

/// One calendar day of recordings, newest first.
struct HistoryDayGroup: Identifiable, Equatable {
    let day: Date
    var entries: [HistoryEntry]
    var id: Date { day }
}

/// Day grouping, labels and copy text for the history list.
enum HistoryGrouping {

    /// Groups entries (already newest first) by calendar day, keeping order.
    static func byDay(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [HistoryDayGroup] {
        var groups: [HistoryDayGroup] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].entries.append(entry)
            } else if let index = groups.firstIndex(where: { $0.day == day }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(HistoryDayGroup(day: day, entries: [entry]))
            }
        }
        return groups
    }

    /// "Today", "Yesterday", the weekday within a week, otherwise a date.
    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 {
            formatter.dateFormat = "EEEE"
        } else if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "EEEE, MMMM d"
        } else {
            formatter.dateFormat = "MMMM d, yyyy"
        }
        return formatter.string(from: day)
    }

    /// The detail header date, `MMM d, yyyy 'at' h:mm a`.
    static func detailDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }

    /// "0:07", "12:45", "1:02:03".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "0.4 s" or "850 ms".
    static func secondsText(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    /// The text a row shows and copies: final, else LLM, else raw.
    static func displayText(_ entry: HistoryEntry) -> String {
        for text in [entry.finalText, entry.llmText ?? "", entry.rawTranscript] where !text.isEmpty {
            return text
        }
        return ""
    }

    /// Several recordings as one block for the clipboard: oldest first,
    /// each with its date and time, separated by blank lines.
    static func copyText(for entries: [HistoryEntry], timeZone: TimeZone = .current) -> String {
        entries.sorted { $0.timestamp < $1.timestamp }
            .map { "\(detailDate($0.timestamp, timeZone: timeZone))\n\(displayText($0))" }
            .joined(separator: "\n\n")
    }
}

/// Finds words to highlight for a search, approximating the Porter stemmer
/// the index uses: a word matches when it starts with a query term's stem,
/// ignoring case and diacritics.
enum SearchHighlighter {

    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let stems = terms(query).map(stem).filter { !$0.isEmpty }
        guard !stems.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let folded = fold(word)
            if stems.contains(where: { folded.hasPrefix($0) }) { ranges.append(range) }
        }
        return ranges
    }

    /// The query's words, folded.
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { fold(String($0)) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// A light suffix strip: running, runs, runner's stem is "run".
    static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ingly", "edly", "ing", "ers", "er", "ed", "es", "ly", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            w = String(w.dropLast(suffix.count))
            break
        }
        // Undouble a final consonant left by the strip ("runn" to "run").
        if w.count >= 4, let last = w.last, let previous = w.dropLast().last, last == previous, !"aeiou".contains(last) {
            w = String(w.dropLast())
        }
        return w
    }
}
