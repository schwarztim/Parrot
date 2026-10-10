import Foundation

/// Tone: the formality slider's stops, the TONE block each adds to the
/// prompt, and the live example under the slider. [LLM]
///
/// A tone changes casing, punctuation and word forms only, never meaning or
/// structure. Balanced (and an unset tone) adds nothing.
extension Tone {

    /// Slider order, casual to formal.
    static let sliderOrder: [Tone] = [.casual, .semiCasual, .balanced, .semiFormal, .formal]

    /// Position on the slider, 0 (casual) to 4 (formal).
    var sliderIndex: Int {
        Tone.sliderOrder.firstIndex(of: self) ?? 2
    }

    /// The stop at a slider position, clamped to the ends.
    init(sliderIndex: Int) {
        self = Tone.sliderOrder[min(max(sliderIndex, 0), Tone.sliderOrder.count - 1)]
    }

    var displayName: String {
        switch self {
        case .casual: return "Casual"
        case .semiCasual: return "Semi-casual"
        case .balanced: return "Balanced"
        case .semiFormal: return "Semi-formal"
        case .formal: return "Formal"
        }
    }

    /// The TONE block for the prompt; nil for balanced.
    var promptBlock: String? {
        let lead = "Adjust only casing, punctuation and word forms; never change meaning or structure."
        let script = "Languages that do not use the Latin alphabet keep their own conventions and register."
        switch self {
        case .balanced:
            return nil
        case .formal:
            return """
                TONE: formal. \(lead) Start every sentence with a capital letter and end it with \
                punctuation. Write contractions and casual reductions out in full ("gonna" becomes \
                "going to", "don't" becomes "do not"). Use no exclamation marks. Keep regional and \
                dialect words. \(script)
                """
        case .semiFormal:
            return """
                TONE: semi-formal. \(lead) Start every sentence with a capital letter and end it with \
                punctuation. Write casual reductions out in full ("gonna" becomes "going to") but keep \
                ordinary contractions such as "don't". \(script)
                """
        case .semiCasual:
            return """
                TONE: semi-casual. \(lead) Start sentences in lowercase, but keep capitals for names, \
                acronyms and the word "I". Leave off the final period. \(script)
                """
        case .casual:
            return """
                TONE: casual. \(lead) Write everything in lowercase and leave off the final period. \
                \(script)
                """
        }
    }

    /// What the speaker said in the slider's example.
    static let exampleInput = "hey im gonna be ten minutes late dont wait for me to start"

    /// The example as this tone writes it.
    var example: String {
        switch self {
        case .casual: return "hey i'm gonna be ten minutes late, don't wait for me to start"
        case .semiCasual: return "hey I'm gonna be ten minutes late, don't wait for me to start"
        case .balanced: return "Hey, I'm gonna be ten minutes late. Don't wait for me to start."
        case .semiFormal: return "Hey, I'm going to be ten minutes late. Don't wait for me to start."
        case .formal: return "Hey, I am going to be ten minutes late. Do not wait for me to start."
        }
    }
}
