import Foundation

/// Cleans a language model's reply down to the text to paste. [LLM]
///
/// - Reasoning blocks (`<think>`, `<thinking>`, `<thought>`, `<reasoning>`)
///   are removed. A reply that only closes the tag (the opening was eaten by
///   a chat template) keeps what follows the last closing tag; an opening
///   tag that never closes means the reply was all reasoning.
/// - A leading line that is only "think", "thinking" or "thought" (a label
///   some models print) is dropped.
/// - A response wrapper (`<response>`, `<output>`, `<answer>`, `<result>`)
///   keeps only its inside.
/// - A code fence around the whole reply is unwrapped.
enum OutputCleaner {

    private static let thinkTags = ["think", "thinking", "thought", "reasoning"]
    private static let wrapperTags = [ModePresets.responseTag, "output", "answer", "result"]

    static func clean(_ raw: String) -> String {
        var text = raw
        for tag in thinkTags {
            text = stripBlocks(tag, from: text)
        }
        text = dropLeadingThoughtLabels(text)
        // Parrot's own wrapper counts anywhere (it may follow a stray lead-in);
        // the generic ones only when they open the reply, so dictated markup
        // such as "<output>" in the middle of code survives.
        for tag in wrapperTags {
            let opensReply = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<\(tag)>")
            guard tag == ModePresets.responseTag || opensReply else { continue }
            if let inner = unwrap(tag, in: text) {
                text = inner
                break
            }
        }
        text = unfence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Steps

    private static func stripBlocks(_ tag: String, from input: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var text = input
        // A closing tag with no opening before it: keep what follows.
        if let closeRange = text.range(of: close, options: [.caseInsensitive, .backwards]),
           text.range(of: open, options: .caseInsensitive, range: text.startIndex..<closeRange.lowerBound) == nil
        {
            text = String(text[closeRange.upperBound...])
        }
        while let openRange = text.range(of: open, options: .caseInsensitive) {
            if let closeRange = text.range(of: close, options: .caseInsensitive, range: openRange.upperBound..<text.endIndex) {
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                // Never closed: everything after it is reasoning.
                text = String(text[..<openRange.lowerBound])
            }
        }
        return text
    }

    private static func dropLeadingThoughtLabels(_ input: String) -> String {
        var lines = input.components(separatedBy: "\n")
        let labels: Set<String> = ["think", "thinking", "thought"]
        while let first = lines.first, lines.count > 1 {
            let word = first.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":.…"))
                .lowercased()
            if word.isEmpty || labels.contains(word) {
                lines.removeFirst()
            } else {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func unwrap(_ tag: String, in text: String) -> String? {
        guard let openRange = text.range(of: "<\(tag)>", options: .caseInsensitive) else { return nil }
        if let closeRange = text.range(of: "</\(tag)>", options: [.caseInsensitive, .backwards]),
           closeRange.lowerBound >= openRange.upperBound
        {
            return String(text[openRange.upperBound..<closeRange.lowerBound])
        }
        return String(text[openRange.upperBound...])
    }

    private static func unfence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var inner = String(text.dropFirst(3).dropLast(3))
        // Drop a language tag on the opening line ("```text").
        if let newline = inner.firstIndex(of: "\n") {
            let tag = inner[..<newline].trimmingCharacters(in: .whitespaces)
            if !tag.contains(" ") { inner = String(inner[inner.index(after: newline)...]) }
        }
        guard !inner.contains("```") else { return text }
        return inner
    }
}
