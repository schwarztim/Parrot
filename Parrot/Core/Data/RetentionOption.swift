import Foundation

/// "Keep recordings for" choices. Stored as days in
/// `parrot.historyRetentionDays`; 0 keeps recordings forever. [DATA]
enum RetentionOption: Int, CaseIterable, Identifiable {
    case forever = 0
    case oneDay = 1
    case oneWeek = 7
    case twoWeeks = 14
    case oneMonth = 30
    case sixMonths = 180
    case oneYear = 365

    var id: Int { rawValue }
    var days: Int { rawValue }

    var label: String {
        switch self {
        case .forever: return "Forever"
        case .oneDay: return "1 day"
        case .oneWeek: return "1 week"
        case .twoWeeks: return "2 weeks"
        case .oneMonth: return "1 month"
        case .sixMonths: return "6 months"
        case .oneYear: return "1 year"
        }
    }

    /// The label for any stored value, including ones older builds saved
    /// that are not in this list (for example 90 days).
    static func label(forDays days: Int) -> String {
        if let option = RetentionOption(rawValue: max(0, days)) { return option.label }
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Picker choices: the standard list plus the stored value when it is
    /// not one of them, so the picker never shows a blank selection.
    static func choices(including days: Int) -> [Int] {
        let standard = allCases.map(\.days)
        guard days > 0, !standard.contains(days) else { return standard }
        return (standard + [days]).sorted { a, b in
            // Forever stays first.
            a == 0 ? true : (b == 0 ? false : a < b)
        }
    }

    /// True when moving from `current` to `proposed` can delete recordings
    /// (a shorter, non-forever period), so a confirmation is needed.
    static func needsConfirmation(from current: Int, to proposed: Int) -> Bool {
        guard proposed > 0 else { return false }
        return current == 0 || proposed < current
    }

    /// The confirmation text for a change that deletes `count` recordings.
    static func confirmationMessage(count: Int) -> String {
        let noun = count == 1 ? "recording" : "recordings"
        return "This will delete \(count) \(noun) and their audio. This action cannot be undone."
    }
}
