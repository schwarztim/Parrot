import SwiftUI

// MARK: - Scoring

/// One typing test result.
struct TypingScore: Equatable {
    var wpm: Double
    var correctCharacters: Int
    var typedCharacters: Int
    var wordsCorrect: Int
}

/// The typing speed test's prompts and scoring (ui 5.4). Pure. [UI]
enum TypingTest {

    /// Parrot's own practice paragraphs.
    static let prompts: [String] = [
        "Juniper the parrot hopped across the kitchen table, picked up a bright red pepper, and dropped it into a cup of warm tea while everyone laughed.",
        "Every morning the baker opens the shop at six, lines the window with fresh loaves, and waves at the first commuters hurrying toward the station.",
        "Clear writing starts with a clear thought. Say what you mean in plain words, cut what you do not need, and read it aloud before you send it.",
        "The river bends twice before it reaches the old mill, where moss covers the stones and a wooden wheel still turns slowly in the current.",
        "Pack a jacket, a flashlight, and two extra batteries. The trail is easy in daylight, but the view from the ridge is best just after sunset.",
        "Our team meets on Thursdays to review the roadmap, share quick wins, and pick one small problem that we can fix together before Friday.",
        "Five lively zebras jumped over a quiet fox while the jungle drums kept time, and nobody could explain why the parrot was humming along.",
        "Good habits grow from tiny steps: drink a glass of water, stretch for a minute, and write down the one thing you want to finish today.",
    ]

    /// Slowest and fastest speeds the test saves.
    static let savedRange: ClosedRange<Double> = 5...250

    /// Scores `typed` against `prompt` after `elapsed` seconds.
    ///
    /// Characters count as correct where they match the prompt at the same
    /// position. Speed is correct characters per minute divided by five (one
    /// standard word). Words count as correct where the typed word equals
    /// the prompt word at the same index.
    static func score(prompt: String, typed: String, elapsed: TimeInterval) -> TypingScore {
        let correct = zip(prompt, typed).filter { $0 == $1 }.count
        let minutes = elapsed / 60
        let wpm = minutes > 0 ? Double(correct) / 5 / minutes : 0
        let promptWords = prompt.split(whereSeparator: \.isWhitespace)
        let typedWords = typed.split(whereSeparator: \.isWhitespace)
        let wordsCorrect = zip(promptWords, typedWords).filter { $0 == $1 }.count
        return TypingScore(wpm: wpm, correctCharacters: correct, typedCharacters: typed.count, wordsCorrect: wordsCorrect)
    }

    /// The speed to save, rounded, or nil when too little was typed to trust.
    static func savedWPM(for score: TypingScore) -> Double? {
        guard score.correctCharacters >= 10, score.wpm >= savedRange.lowerBound else { return nil }
        return min(savedRange.upperBound, score.wpm.rounded())
    }

    /// The prompt after `index`, wrapping around.
    static func nextPromptIndex(after index: Int) -> Int {
        (index + 1) % prompts.count
    }
}

// MARK: - Sheet

/// The typing speed test sheet: the timer starts on the first keystroke;
/// Save writes the speed used for time saved.
struct TypingTestView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    @State private var promptIndex = 0
    @State private var typed = ""
    @State private var startedAt: Date?
    @State private var finishedAt: Date?
    @FocusState private var focused: Bool

    private var prompt: String { TypingTest.prompts[promptIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Typing speed test")
                .font(.title2.weight(.semibold))
            Text("Type the text below. The timer starts with your first key.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(prompt)
                .font(.system(.body, design: .serif))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
                .textSelection(.disabled)

            TextField("Start typing...", text: $typed, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .focused($focused)
                .onChange(of: typed) { old, new in
                    if old.isEmpty, !new.isEmpty, startedAt == nil { startedAt = Date() }
                    if new.count >= prompt.count, finishedAt == nil { finishedAt = Date() }
                }
                .disabled(finishedAt != nil)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let score = currentScore(now: context.date)
                HStack(spacing: 24) {
                    stat(String(format: "%.0f", score.wpm), "WPM")
                    stat("\(score.wordsCorrect)", "Words correct")
                    stat("\(appSettings.general.typingWPM.formatted(.number.precision(.fractionLength(0))))", "Saved speed")
                }
            }

            HStack {
                Button("Retry") { retry() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let wpm = TypingTest.savedWPM(for: currentScore(now: Date())) {
                        appSettings.general.typingWPM = wpm
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TypingTest.savedWPM(for: currentScore(now: Date())) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            promptIndex = Int.random(in: 0..<TypingTest.prompts.count)
            focused = true
        }
    }

    private func currentScore(now: Date) -> TypingScore {
        guard let startedAt else { return TypingScore(wpm: 0, correctCharacters: 0, typedCharacters: 0, wordsCorrect: 0) }
        let end = finishedAt ?? now
        return TypingTest.score(prompt: prompt, typed: typed, elapsed: end.timeIntervalSince(startedAt))
    }

    private func retry() {
        promptIndex = TypingTest.nextPromptIndex(after: promptIndex)
        typed = ""
        startedAt = nil
        finishedAt = nil
        focused = true
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
