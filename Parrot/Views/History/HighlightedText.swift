import SwiftUI

/// Text with the words matching a search highlighted. [DATA]
struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(Self.attributed(text, query: query))
    }

    static func attributed(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in SearchHighlighter.ranges(in: text, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
            attributed[lower..<upper].foregroundColor = Color.primary
        }
        return attributed
    }
}
