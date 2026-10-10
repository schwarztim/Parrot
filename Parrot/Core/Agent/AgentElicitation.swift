import Foundation

/// Answering an agent's questions one step at a time. [AGT]
///
/// Holds the questions from Claude's AskUserQuestion, the step on screen,
/// the keyboard focus and the choices so far. Answers are collected for
/// every step and sent together. A step can also take a spoken or typed
/// answer that is not one of the options.
struct AgentElicitation: Equatable {

    let questions: [HookQuestion]
    private(set) var step = 0
    /// Chosen labels per step, in option order.
    private(set) var selections: [Int: [String]] = [:]
    /// A free answer per step (replaces any chosen labels).
    private(set) var freeText: [Int: String] = [:]
    /// Keyboard focus among the current step's options.
    private(set) var focusIndex = 0

    init(questions: [HookQuestion]) {
        self.questions = questions
    }

    var current: HookQuestion { questions[min(step, questions.count - 1)] }
    var isMultiStep: Bool { questions.count > 1 }
    var isLastStep: Bool { step >= questions.count - 1 }

    func isSelected(_ label: String) -> Bool {
        selections[step]?.contains(label) ?? false
    }

    func isAnswered(step index: Int) -> Bool {
        !(selections[index] ?? []).isEmpty || !(freeText[index] ?? "").isEmpty
    }

    var currentStepAnswered: Bool { isAnswered(step: step) }

    /// Every step has an answer.
    var isComplete: Bool {
        questions.indices.allSatisfy(isAnswered(step:))
    }

    // MARK: Choosing

    /// Picks `label` on the current step: single select replaces, multi
    /// select toggles. Returns true when a single-select pick finished the
    /// step (the panel then advances, or sends on the last step).
    @discardableResult
    mutating func choose(_ label: String) -> Bool {
        guard let index = current.options.firstIndex(where: { $0.label == label }) else { return false }
        focusIndex = index
        freeText[step] = nil
        if current.multiSelect {
            var chosen = Set(selections[step] ?? [])
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
            selections[step] = current.options.map(\.label).filter(chosen.contains)
            return false
        }
        selections[step] = [label]
        return true
    }

    /// Answers the current step with text that is not one of the options.
    mutating func setFreeText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        freeText[step] = trimmed
        selections[step] = nil
    }

    /// Applies dictated text: option names it mentions are chosen, anything
    /// else becomes the free answer. Returns true when a single-select step
    /// is now finished.
    @discardableResult
    mutating func applySpoken(_ text: String) -> Bool {
        let matches = Self.match(text, in: current)
        if matches.isEmpty {
            setFreeText(text)
            return !current.multiSelect && currentStepAnswered
        }
        if current.multiSelect {
            freeText[step] = nil
            selections[step] = current.options.map(\.label).filter(Set(matches).contains)
            return false
        }
        return choose(matches[0])
    }

    // MARK: Moving

    /// Goes to the next step; false on the last one.
    @discardableResult
    mutating func next() -> Bool {
        guard !isLastStep else { return false }
        step += 1
        focusIndex = 0
        return true
    }

    mutating func back() {
        guard step > 0 else { return }
        step -= 1
        focusIndex = 0
    }

    mutating func moveFocus(_ delta: Int) {
        let count = current.options.count
        guard count > 0 else { return }
        focusIndex = (focusIndex + delta % count + count) % count
    }

    /// Picks the focused option (Return or Space).
    @discardableResult
    mutating func chooseFocused() -> Bool {
        guard current.options.indices.contains(focusIndex) else { return false }
        return choose(current.options[focusIndex].label)
    }

    // MARK: Answers

    /// Question text to chosen labels (or the free answer), for every
    /// answered step.
    func answers() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (index, question) in questions.enumerated() {
            if let text = freeText[index], !text.isEmpty {
                result[question.question] = [text]
            } else if let chosen = selections[index], !chosen.isEmpty {
                result[question.question] = chosen
            }
        }
        return result
    }

    // MARK: Matching Speech

    private static let ordinals: [String: Int] = [
        "one": 1, "first": 1, "1": 1, "two": 2, "second": 2, "2": 2,
        "three": 3, "third": 3, "3": 3, "four": 4, "fourth": 4, "4": 4,
        "five": 5, "fifth": 5, "5": 5, "six": 6, "sixth": 6, "6": 6,
    ]

    /// Option labels named in `spoken`: the whole utterance equal to a
    /// label, "option two" or "the second one", or labels it mentions.
    static func match(_ spoken: String, in question: HookQuestion) -> [String] {
        let said = normalize(spoken)
        guard !said.isEmpty else { return [] }
        let labels = question.options.map(\.label)

        if let exact = labels.first(where: { normalize($0) == said }) {
            return [exact]
        }

        let words = said.split(separator: " ").map(String.init)
        if words.count <= 3, let number = words.lazy.compactMap({ ordinals[$0] }).first,
           words.allSatisfy({ ordinals[$0] != nil || ["option", "number", "the", "one", "choice"].contains($0) }),
           labels.indices.contains(number - 1) {
            return [labels[number - 1]]
        }

        let padded = " \(said) "
        let mentioned = labels.filter { label in
            let name = normalize(label)
            return !name.isEmpty && padded.contains(" \(name) ")
        }
        return mentioned
    }

    /// Lowercased words without punctuation, single spaces.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
