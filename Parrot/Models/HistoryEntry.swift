import Foundation

/// One dictation stored in the history database.
struct HistoryEntry: Identifiable, Equatable {
    let id: Int64
    let timestamp: Date
    let rawTranscript: String
    var finalText: String
    let appBundleID: String?
    let modeName: String?
}
