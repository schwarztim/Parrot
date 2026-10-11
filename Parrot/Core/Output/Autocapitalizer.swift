import Foundation

// MARK: - CursorContext

/// The text around the caret in the focused field, read just before the
/// paste. [OUT]
struct CursorContext: Equatable, Sendable {
    /// The character right before the caret (or the selection), nil at the
    /// start of the field.
    var characterBefore: Character?
    /// The character right after the caret (or the selection).
    var characterAfter: Character?
    /// The last meaningful character before the caret: whitespace and
    /// closing quotes or brackets are skipped, so `"Done." ` reads as ".".
    var lastNonWhitespaceBefore: Character?
    /// A line break sits between `lastNonWhitespaceBefore` and the caret.
    var newlineBeforeCaret: Bool

    init(
        characterBefore: Character? = nil,
        characterAfter: Character? = nil,
        lastNonWhitespaceBefore: Character? = nil,
        newlineBeforeCaret: Bool = false
    ) {
        self.characterBefore = characterBefore
        self.characterAfter = characterAfter
        self.lastNonWhitespaceBefore = lastNonWhitespaceBefore
        self.newlineBeforeCaret = newlineBeforeCaret
    }

    /// Builds the context from the text before and after the caret.
    init(before: String, after: String) {
        characterBefore = before.last
        characterAfter = after.first
        let skipped = before.reversed().prefix { $0.isWhitespace || Autocapitalizer.closers.contains($0) }
        newlineBeforeCaret = skipped.contains { $0.isNewline }
        lastNonWhitespaceBefore = before.dropLast(skipped.count).last
    }

    /// Builds the context from a field's full text and its selection, in
    /// UTF-16 offsets as Accessibility reports them. Nil when the selection
    /// lies outside the text.
    init?(text: String, selection: NSRange) {
        let string = text as NSString
        guard selection.location != NSNotFound,
              selection.location >= 0,
              selection.location + selection.length <= string.length
        else { return nil }
        let windowStart = max(0, selection.location - 200)
        let before = string.substring(with: NSRange(location: windowStart, length: selection.location - windowStart))
        let end = selection.location + selection.length
        let after = string.substring(with: NSRange(location: end, length: min(8, string.length - end)))
        self.init(before: before, after: after)
    }
}

// MARK: - Autocapitalizer

/// Adjusts the first word of a dictation to the caret's context: capital at
/// a sentence start, lowercase mid-sentence, and a leading space when the
/// caret sits right after a word. Pure. [OUT]
enum Autocapitalizer {

    static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    /// Skipped when looking back for the last meaningful character.
    static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»"]
    /// After these no space is added: the dictation continues them.
    static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "«", "/", "-", "@", "#", "$", "_"]
    /// A dictation starting with one of these attaches to the text before it.
    static let attachingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "’", "…", "%"]

    /// The dictation as it should be inserted at `context`, leading space
    /// included. Unchanged when there is no context.
    static func apply(_ text: String, context: CursorContext?) -> String {
        guard let context else { return text }
        let adjusted = adjustCase(text, context: context)
        return needsLeadingSpace(adjusted, context: context) ? " " + adjusted : adjusted
    }

    /// True when the caret is at the start of a sentence: an empty field, a
    /// new line, or right after ". ! ?".
    static func isSentenceStart(_ context: CursorContext) -> Bool {
        guard let last = context.lastNonWhitespaceBefore else { return true }
        return context.newlineBeforeCaret || sentenceEnders.contains(last)
    }

    /// Capitalizes or lowercases the first letter of the first word.
    static func adjustCase(_ text: String, context: CursorContext) -> String {
        guard let index = firstLetterIndex(text) else { return text }
        let letter = text[index]
        let range = index..<text.index(after: index)
        if isSentenceStart(context) {
            return text.replacingCharacters(in: range, with: letter.uppercased())
        }
        guard letter.isUppercase, !keepsCapital(firstWord(text, from: index)) else { return text }
        return text.replacingCharacters(in: range, with: letter.lowercased())
    }

    /// True when the caret sits right after a word or punctuation, so the
    /// dictation needs a space in front.
    static func needsLeadingSpace(_ text: String, context: CursorContext) -> Bool {
        guard let before = context.characterBefore, !before.isWhitespace, !openers.contains(before),
              let first = text.first, !first.isWhitespace, !attachingPunctuation.contains(first)
        else { return false }
        return true
    }

    // MARK: Private

    /// The first character of the first word, past leading quotes and
    /// brackets, when it is a letter.
    private static func firstLetterIndex(_ text: String) -> String.Index? {
        guard let index = text.firstIndex(where: { !$0.isWhitespace && !openers.contains($0) }),
              text[index].isLetter
        else { return nil }
        return index
    }

    private static func firstWord(_ text: String, from index: String.Index) -> Substring {
        let rest = text[index...]
        return rest.prefix { !$0.isWhitespace }
    }

    /// "I" and its contractions, and words with a capital past the first
    /// letter (NASA, McDonald), keep their case mid-sentence.
    private static func keepsCapital(_ word: Substring) -> Bool {
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        if bare == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") {
            return true
        }
        return word.dropFirst().contains { $0.isUppercase }
    }
}
