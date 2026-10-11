import Foundation

// MARK: - Hallucinations

/// Recognizers sometimes invent a stock phrase when they hear silence or
/// noise. Parrot's own list of such phrases; a transcript is dropped only
/// when the whole of it is one of them, never a phrase inside real
/// dictation. [ASR]
enum HallucinationFilter {

    /// Always invented: nobody dictates these as a whole message.
    static let stockPhrases: Set<String> = [
        "thanks for watching",
        "thank you for watching",
        "thanks for watching see you next time",
        "thank you so much for watching",
        "thank you very much for watching",
        "please subscribe",
        "please like and subscribe",
        "like and subscribe",
        "dont forget to like and subscribe",
        "subscribe to my channel",
        "see you in the next video",
        "ill see you in the next video",
        "see you next time",
        "subtitles by the amaraorg community",
        "subtitles by the amara org community",
        "transcription by castingwords",
        "blank audio",
        "no speech",
        "silence",
        "music",
        "music playing",
        "applause",
        "inaudible",
    ]

    /// Credit lines are invented with varying names, so they match by
    /// their opening words, and only when the whole transcript is short.
    static let creditPrefixes = [
        "subtitles by", "subtitled by", "captions by", "captioned by", "closed captions by",
        "closed captioning by", "captioning by", "transcribed by", "transcription by",
        "translated by", "translation by", "subtitles provided by", "subtitles created by",
    ]

    /// Real words a recognizer also invents from silence. Dropped only when
    /// the detector heard almost no speech in the recording.
    static let silencePhrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "you", "bye", "bye bye", "goodbye",
        "okay", "ok", "so", "oh", "um", "uh", "hmm", "mm", "huh", "yeah",
    ]

    /// Below this much detected speech, `silencePhrases` count as invented.
    static let silenceSpeechSeconds: TimeInterval = 0.3

    /// Lowercase letters and digits, single spaces, no punctuation.
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return "\u{0}"
        }
        let joined = String(kept).replacingOccurrences(of: "\u{0}", with: "")
        return joined.split(separator: " ").joined(separator: " ")
    }

    /// True when the whole transcript is invented.
    /// - Parameter speechSeconds: Speech the detector found, or nil when it
    ///   did not run (the short silence phrases are then kept).
    static func isHallucination(_ text: String, speechSeconds: TimeInterval?) -> Bool {
        // Only tags like "[Music]", "(upbeat music)" or "♪♪": nothing said.
        let untagged = text.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|<[^>]*>"#, with: " ", options: .regularExpression
        )
        let normalized = normalize(untagged)
        if normalized.isEmpty { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if stockPhrases.contains(normalized) { return true }
        let wordCount = normalized.split(separator: " ").count
        if wordCount <= 12, creditPrefixes.contains(where: { normalized.hasPrefix($0 + " ") }) {
            return true
        }
        if let speechSeconds, speechSeconds < silenceSpeechSeconds, silencePhrases.contains(normalized) {
            return true
        }
        return false
    }

    /// Drops segments that start after the audio ends; they cannot be real.
    static func dropSegmentsPastEnd(
        _ segments: [TranscriptSegment], duration: TimeInterval
    ) -> (kept: [TranscriptSegment], dropped: Int) {
        let kept = segments.filter { $0.start < duration }
        return (kept, segments.count - kept.count)
    }
}

// MARK: - Literal Punctuation

/// Turns spoken punctuation words into symbols: "comma" to ",", "new
/// line" to a line break, and so on. A word matches with either case on
/// its first letter. Stray commas, periods and spaces the recognizer put
/// around the spoken word are absorbed, so "Hello, comma, world." becomes
/// "Hello, world." [ASR]
enum LiteralPunctuation {

    /// How a symbol joins its neighbors.
    private enum Attach {
        /// Sticks to the word before: "word," then a space.
        case left
        /// Joins both neighbors with no spaces: "and/or".
        case both
        /// Replaces the surrounding spaces: a line break.
        case line
    }

    private struct Command {
        let pattern: String
        let symbol: String
        let attach: Attach
    }

    /// `w("question mark")` matches "question mark", "Question Mark",
    /// "question-mark" and "questionmark".
    private static func w(_ phrase: String) -> String {
        phrase.split(separator: " ").map { word -> String in
            let first = word.prefix(1)
            return "[\(first.lowercased())\(first.uppercased())]\(word.dropFirst())"
        }.joined(separator: "[ -]?")
    }

    /// Longer phrases first so "new paragraph" wins over "new line" and
    /// "semicolon" over "colon".
    private static let commands: [Command] = [
        Command(pattern: w("new paragraph"), symbol: "\n\n", attach: .line),
        Command(pattern: w("new line"), symbol: "\n", attach: .line),
        Command(pattern: w("question mark"), symbol: "?", attach: .left),
        Command(pattern: w("exclamation mark"), symbol: "!", attach: .left),
        Command(pattern: w("exclamation point"), symbol: "!", attach: .left),
        Command(pattern: w("full stop"), symbol: ".", attach: .left),
        Command(pattern: w("period"), symbol: ".", attach: .left),
        Command(pattern: w("semi colon"), symbol: ";", attach: .left),
        Command(pattern: w("colon"), symbol: ":", attach: .left),
        Command(pattern: w("comma"), symbol: ",", attach: .left),
        Command(pattern: w("slash"), symbol: "/", attach: .both),
        Command(pattern: w("dash"), symbol: "-", attach: .both),
        Command(pattern: w("hyphen"), symbol: "-", attach: .both),
    ]

    /// Compiled once: (regex, template).
    private static let compiled: [(NSRegularExpression, String)] = commands.compactMap { command in
        // The spoken word, not inside a longer word or hyphenated compound.
        let word = "(?<![\\p{L}\\p{N}-])(?:\(command.pattern))(?![\\p{L}\\p{N}-])"
        let pattern: String
        switch command.attach {
        case .left:
            pattern = "[ \\t]*[,.;:]?[ \\t]*\(word)[,.;:]?"
        case .both:
            pattern = "[ \\t]*,?[ \\t]*\(word)[,.]?[ \\t]*"
        case .line:
            pattern = "[ \\t]*[,.;:]?[ \\t]*\(word)[,.;:]?[ \\t]*"
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, NSRegularExpression.escapedTemplate(for: command.symbol))
    }

    static func apply(_ text: String) -> String {
        var result = text
        for (regex, template) in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        // Spaces a removed word left at the very start.
        return result.replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression)
    }
}
