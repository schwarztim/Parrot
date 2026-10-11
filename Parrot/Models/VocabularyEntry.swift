import Foundation

/// One vocabulary item: a word (a recognition hint) or a replacement.
///
/// A word is stored with `replacement` equal to `original`, so recognizer
/// boosting (which boosts `replacement`) picks it up and find and replace
/// leaves the transcript alone. A replacement maps `original` to different
/// text: a spelling, a link or a longer snippet.
struct VocabularyEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var original: String
    var replacement: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        original: String,
        replacement: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.isEnabled = isEnabled
    }

    /// A vocabulary word: boosted, never replaced.
    static func word(_ word: String, id: UUID = UUID(), isEnabled: Bool = true) -> VocabularyEntry {
        VocabularyEntry(id: id, original: word, replacement: word, isEnabled: isEnabled)
    }

    /// True for a word (no replacement text of its own).
    var isWord: Bool { replacement.isEmpty || replacement == original }
}
