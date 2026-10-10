import Foundation

/// Manages a list of vocabulary replacement entries.
///
/// Replacements are applied case-insensitively with case-preserving output:
/// if the matched text is all-uppercase the replacement is uppercased, and if
/// the first character is uppercase the replacement is capitalized.
///
/// The single source of truth for vocabulary: the Vocabulary tab edits it
/// (through `AppState.vocabularyEntries`), and find and replace plus
/// recognizer boosting read it. Every change is saved to a JSON file in
/// Application Support.
@Observable
final class VocabularyManager {

    // MARK: - State

    private(set) var entries: [VocabularyEntry] = []

    // MARK: - Persistence

    private let storageURL: URL

    static func defaultStorageURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }

    // MARK: - Initialization

    /// - Parameter storageURL: JSON file to load from and save to. Tests pass
    ///   a temporary file; the app uses the default.
    init(storageURL: URL = VocabularyManager.defaultStorageURL()) {
        self.storageURL = storageURL
        load()
    }

    // MARK: - CRUD

    func addEntry(original: String, replacement: String) {
        let entry = VocabularyEntry(original: original, replacement: replacement)
        entries.append(entry)
        save()
    }

    func updateEntry(_ entry: VocabularyEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Replaces the whole list (the Vocabulary tab edits a copy) and saves.
    func replaceAll(_ newEntries: [VocabularyEntry]) {
        entries = newEntries
        save()
    }

    // MARK: - Replacement Engine

    /// Applies all enabled vocabulary entries to the given text.
    ///
    /// Matching is case-insensitive. The replacement preserves the case of the
    /// matched text:
    /// - All-uppercase match -> all-uppercase replacement
    /// - Title-case match -> title-case replacement
    /// - Otherwise -> replacement as-is
    func apply(to text: String) -> String {
        Self.apply(entries: entries, to: text)
    }

    /// Pure, storage-free application of vocabulary entries to text. Exposed as
    /// a static function so it can be tested without touching the persisted
    /// vocabulary file.
    static func apply(entries: [VocabularyEntry], to text: String) -> String {
        var result = text
        for entry in entries where entry.isEnabled && !entry.original.isEmpty {
            result = replacePreservingCase(
                in: result,
                target: entry.original,
                replacement: entry.replacement
            )
        }
        return result
    }

    // MARK: - Private Helpers

    private static func replacePreservingCase(
        in text: String,
        target: String,
        replacement: String
    ) -> String {
        var output = ""
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(
            of: target,
            options: .caseInsensitive,
            range: searchRange
        ) {
            // Only replace whole-word matches so "cat" does not fire inside
            // "concatenate". Boundaries are only required on a side where the
            // target itself ends in a word character.
            if isWordBoundaryMatch(range, in: text, target: target) {
                output += text[searchRange.lowerBound..<range.lowerBound]
                let matched = String(text[range])
                output += adjustCase(of: replacement, toMatch: matched)
                searchRange = range.upperBound..<text.endIndex
            } else {
                // Keep the matched text as-is and advance past its first
                // character so overlapping matches are still found.
                let next = text.index(after: range.lowerBound)
                output += text[searchRange.lowerBound..<next]
                searchRange = next..<text.endIndex
            }
        }

        output += text[searchRange]
        return output
    }

    /// True when the matched range sits on word boundaries. A boundary is only
    /// enforced on a side whose adjacent target character is a word character
    /// (letter or digit), so targets that begin or end with punctuation still
    /// match mid-word on that side.
    private static func isWordBoundaryMatch(
        _ range: Range<String.Index>,
        in text: String,
        target: String
    ) -> Bool {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        if let first = target.first, isWord(first), range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isWord(before) { return false }
        }
        if let last = target.last, isWord(last), range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if isWord(after) { return false }
        }
        return true
    }

    private static func adjustCase(of replacement: String, toMatch matched: String) -> String {
        guard !matched.isEmpty, !replacement.isEmpty else { return replacement }

        let isAllUppercase = matched == matched.uppercased() && matched != matched.lowercased()
        if isAllUppercase {
            return replacement.uppercased()
        }

        let firstChar = matched[matched.startIndex]
        if firstChar.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }

        return replacement
    }

    // MARK: - Persistence Helpers

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Non-fatal: entries remain in memory.
            diagLog("[Parrot:Vocab] Saving vocabulary failed: \(error)")
        }
    }

    private func load() {
        let url = storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([VocabularyEntry].self, from: data)
        } catch {
            // Non-fatal: start with empty entries.
            entries = []
        }
    }
}
