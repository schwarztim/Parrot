import Foundation

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
}
