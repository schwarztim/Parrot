import Foundation

struct Mode: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var description: String
    var voiceModelVersion: String
    var language: String
    var isDefault: Bool
    /// Per-mode refinement directive. Nil or empty falls back to
    /// `RefinementService.defaultDirective`. Optional so modes saved before
    /// this field existed still decode.
    var refinementPrompt: String?

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        voiceModelVersion: String,
        language: String,
        isDefault: Bool = false,
        refinementPrompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.voiceModelVersion = voiceModelVersion
        self.language = language
        self.isDefault = isDefault
        self.refinementPrompt = refinementPrompt
    }

    /// Creates the built-in default mode.
    static var defaultMode: Mode {
        Mode(
            name: "Default",
            description: "General-purpose transcription mode",
            voiceModelVersion: "v3",
            language: "auto",
            isDefault: true
        )
    }
}
