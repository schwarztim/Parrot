import Foundation

// MARK: - BuiltInExample

/// One built-in few-shot pair. Built-in examples live in the preset, not in
/// the mode file, so a wording change here reaches every mode of that type.
struct BuiltInExample: Equatable, Sendable {
    let input: String
    let output: String
}

// MARK: - ModePreset

/// What a mode type starts with: name, description, icon, instruction,
/// examples and context defaults.
struct ModePreset: Sendable {
    let type: ModeType
    /// File key a seeded preset uses ("super", "email").
    let key: String
    let name: String
    let description: String
    let iconName: String
    /// Built-in instruction. Nil for Voice (no language model) and Custom
    /// (the user writes it; empty falls back to the default directive).
    let instruction: String?
    let examples: [BuiltInExample]
    let contextFromSelection: Bool
    let contextFromClipboard: Bool
    let contextFromActiveApplication: Bool
}

// MARK: - ModePresets

/// Parrot's built-in mode recipes. [LLM]
///
/// The wording is Parrot's own. A mode with an empty `refinementPrompt` uses
/// its type's built-in instruction and examples; Custom falls back to
/// `RefinementService.defaultDirective`, which is what every mode used
/// before presets existed, so legacy modes (decoded as Custom) behave as
/// before. Voice never calls a language model.
enum ModePresets {

    /// Every preset in the order the "Add mode" menu shows them.
    static let all: [ModePreset] = [superPreset, voicePreset, messagePreset, emailPreset, notePreset, meetingPreset, customPreset]

    /// The preset for a type.
    static func preset(for type: ModeType) -> ModePreset {
        all.first { $0.type == type } ?? customPreset
    }

    /// Modes a new install starts with, Super first and selected.
    static var defaultModes: [Mode] {
        [ModeType.super, .voice, .message, .email, .note, .meeting].map { type in
            var mode = make(type)
            mode.isDefault = type == .super
            return mode
        }
    }

    /// A new mode filled from a preset. `key` defaults to the preset's key;
    /// ModeManager makes it unique when it is added.
    static func make(_ type: ModeType, key: String? = nil) -> Mode {
        let preset = preset(for: type)
        return Mode(
            key: key ?? preset.key,
            name: preset.name,
            description: preset.description,
            type: type,
            iconName: preset.iconName,
            contextFromSelection: preset.contextFromSelection,
            contextFromClipboard: preset.contextFromClipboard,
            contextFromActiveApplication: preset.contextFromActiveApplication
        )
    }

    /// Whether this type runs the language model at all.
    static func usesLanguageModel(_ type: ModeType) -> Bool {
        type != .voice
    }

    /// The SF Symbol to show: the mode's own, or its type's.
    static func iconName(for mode: Mode) -> String {
        mode.iconName.isEmpty ? preset(for: mode.type).iconName : mode.iconName
    }

    /// True when the mode uses the built-in instruction (no custom text).
    static func usesBuiltInInstruction(_ mode: Mode) -> Bool {
        (mode.refinementPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The instruction the prompt uses: the mode's own text, else its type's
    /// built-in instruction, else the default cleanup directive.
    static func instruction(for mode: Mode) -> String {
        let custom = (mode.refinementPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return preset(for: mode.type).instruction ?? RefinementService.defaultDirective
    }

    /// Built-in examples for the prompt. They teach the built-in
    /// instruction, so a mode with its own instruction gets only its own
    /// examples.
    static func builtInExamples(for mode: Mode) -> [BuiltInExample] {
        usesBuiltInInstruction(mode) ? preset(for: mode.type).examples : []
    }

    // MARK: - Presets

    /// The wrapper Super asks for; `OutputCleaner` keeps only its inside.
    static let responseTag = "response"

    static let superPreset = ModePreset(
        type: .super,
        key: "super",
        name: "Super",
        description: "Adapts to the app you are typing in, using what is on screen.",
        iconName: "sparkles",
        instruction: """
            Rewrite the dictation so it reads naturally in the app the user is typing into. \
            Use APPLICATION CONTEXT to choose the shape: a chat reply stays short and casual, \
            an email gets paragraphs, and a code editor or terminal gets the literal command \
            or identifier with no prose around it. Fix misheard words, spelling, punctuation \
            and capitalization, and spell names the way they appear in the context or the \
            vocabulary. Keep the user's own words and word order; only drop fillers, false \
            starts and words the speaker took back. Write spoken email addresses and links \
            in their written form ("sam at example dot com" becomes sam@example.com).

            Selected and copied text are background only. Never add them to the output, never \
            borrow their wording, and never use them to decide what a pronoun in the dictation \
            refers to. The one exception: when the whole dictation is a request about that text \
            (for example "make this friendlier", "shorten this" or "translate this into French"), \
            apply the request to the selected or copied text and output only the result.

            Write a person's name as spoken, matching its spelling to a name in the context only \
            when it is clearly the same person. Write an @username only when the speaker says \
            "at" followed by a name that exactly matches a username in the context; never swap \
            a nickname or a loose match for a username.

            If the dictation is empty, output nothing. Put the final text between <response> and \
            </response>, with nothing outside the tags.
            """,
        examples: [
            BuiltInExample(
                input: "(App: Slack) ok sounds good ill take a look after lunch",
                output: "<response>Ok, sounds good. I'll take a look after lunch.</response>"
            ),
            BuiltInExample(
                input: "(Copied text: \"The quarterly report is attached.\") thanks ill read it tonight",
                output: "<response>Thanks, I'll read it tonight.</response>"
            ),
            BuiltInExample(
                input: "(Copied text: \"hey can u send the file\") make this more formal",
                output: "<response>Hello, could you please send the file?</response>"
            ),
            BuiltInExample(
                input: "(App: Terminal) git checkout dash b feature slash login",
                output: "<response>git checkout -b feature/login</response>"
            ),
        ],
        contextFromSelection: true,
        contextFromClipboard: true,
        contextFromActiveApplication: true
    )

    static let voicePreset = ModePreset(
        type: .voice,
        key: "voice",
        name: "Voice",
        description: "Your words as spoken, with no AI rewriting.",
        iconName: "waveform",
        instruction: nil,
        examples: [],
        contextFromSelection: false,
        contextFromClipboard: false,
        contextFromActiveApplication: false
    )

    static let messagePreset = ModePreset(
        type: .message,
        key: "message",
        name: "Message",
        description: "Light cleanup for chats and texts.",
        iconName: "message.fill",
        instruction: """
            Clean up a dictated chat message with the lightest possible touch. Fix punctuation, \
            capitalization, obvious misspellings and wrong homophones. Write spoken numbers, \
            times and dates the way people type them. Remove fillers (um, uh, you know), \
            accidental repeats and anything the speaker corrected. Break a long message into \
            short paragraphs where the topic changes. Turn a spoken emoji name into the emoji \
            only when the speaker clearly means the emoji, for example "thumbs up emoji" \
            becomes 👍. Keep the speaker's tone, slang, hedges and swearing exactly as they \
            are, and never drop a clause.
            """,
        examples: [
            BuiltInExample(
                input: "um hey are we still on for lunch tomorrow at twelve thirty",
                output: "Hey, are we still on for lunch tomorrow at 12:30?"
            ),
            BuiltInExample(
                input: "send it to me on monday sorry i mean tuesday",
                output: "Send it to me on Tuesday."
            ),
            BuiltInExample(
                input: "that demo was honestly so freaking good thumbs up emoji",
                output: "That demo was honestly so freaking good 👍"
            ),
            BuiltInExample(
                input: "i think its there car not ours",
                output: "I think it's their car, not ours."
            ),
        ],
        contextFromSelection: false,
        contextFromClipboard: false,
        contextFromActiveApplication: false
    )

    static let emailPreset = ModePreset(
        type: .email,
        key: "email",
        name: "Email",
        description: "Turns your dictation into a ready-to-send email.",
        iconName: "envelope.fill",
        instruction: """
            Turn the dictation into the body of an email. Keep a greeting the speaker said; \
            otherwise open with a short friendly greeting, using the recipient's name if it was \
            spoken. Split the content into short paragraphs. End with a brief sign-off that fits \
            the tone, unless the speaker dictated one. Write no subject line, add no facts or \
            promises that were not spoken, and put nothing before the email itself.
            """,
        examples: [
            BuiltInExample(
                input: "hi sam just checking if you got the contract i sent over on tuesday let me know if anything needs changing thanks",
                output: "Hi Sam,\n\nJust checking whether you got the contract I sent over on Tuesday. Let me know if anything needs changing.\n\nThanks"
            ),
            BuiltInExample(
                input: "can we move our call to three pm i have a conflict",
                output: "Hi,\n\nCan we move our call to 3 PM? I have a conflict.\n\nBest"
            ),
            BuiltInExample(
                input: "dear professor lee i wanted to ask whether the essay is due friday or monday kind regards alex",
                output: "Dear Professor Lee,\n\nI wanted to ask whether the essay is due Friday or Monday.\n\nKind regards,\nAlex"
            ),
            BuiltInExample(
                input: "hey team quick update the launch moved to the twenty first because of the app review otherwise we are on track cheers",
                output: "Hey team,\n\nQuick update: the launch moved to the 21st because of the app review. Otherwise we are on track.\n\nCheers"
            ),
        ],
        contextFromSelection: false,
        contextFromClipboard: false,
        contextFromActiveApplication: false
    )

    static let notePreset = ModePreset(
        type: .note,
        key: "note",
        name: "Note",
        description: "Organizes your thoughts into headed bullet notes.",
        iconName: "note.text",
        instruction: """
            Turn the dictation into tidy notes. Start with a short heading that names the topic, \
            then list the key points as bullets in the order they were said. Put action items in \
            their own list at the end, each starting with a verb, and leave that list out when \
            there are none. Use only what was said; do not add, infer or expand.
            """,
        examples: [
            BuiltInExample(
                input: "ideas for the garden plant tomatoes along the south fence move the compost bin closer to the shed and i need to buy mulch before saturday",
                output: "# Garden ideas\n\n- Plant tomatoes along the south fence\n- Move the compost bin closer to the shed\n\nAction items:\n- Buy mulch before Saturday"
            ),
            BuiltInExample(
                input: "book notes chapter three the author argues habits form through cues and rewards and the key point is that small changes compound over time",
                output: "# Book notes: chapter 3\n\n- Habits form through cues and rewards\n- Key point: small changes compound over time"
            ),
            BuiltInExample(
                input: "groceries we need eggs oat milk spinach and coffee beans also call the vet about luna's checkup",
                output: "# Groceries\n\n- Eggs\n- Oat milk\n- Spinach\n- Coffee beans\n\nAction items:\n- Call the vet about Luna's checkup"
            ),
        ],
        contextFromSelection: false,
        contextFromClipboard: false,
        contextFromActiveApplication: false
    )

    static let meetingPreset = ModePreset(
        type: .meeting,
        key: "meeting",
        name: "Meeting",
        description: "Summarizes a meeting into decisions and action items.",
        iconName: "person.3.fill",
        instruction: """
            Turn the meeting transcript into meeting notes. Begin with a summary of two or three \
            sentences, then list the decisions, then the action items, leaving out a list that \
            would be empty. Write each action item as the task followed by its owner in \
            parentheses when the transcript names one. Keep speaker labels (Speaker 1, Speaker 2) \
            when the transcript has them. Include only what was actually discussed; never invent \
            owners, dates or decisions.
            """,
        examples: [
            BuiltInExample(
                input: "Speaker 1: so we agreed to ship the beta on the fourth. Speaker 2: yes and i will write the release notes. Speaker 1: great, and priya will check the crash reports",
                output: "Summary: The team agreed on the beta date and split the release tasks.\n\nDecisions:\n- Ship the beta on the 4th\n\nAction items:\n- Write the release notes (Speaker 2)\n- Check the crash reports (Priya)"
            ),
            BuiltInExample(
                input: "we talked about the budget and nobody could agree so we will revisit it next week",
                output: "Summary: The budget was discussed without agreement.\n\nAction items:\n- Revisit the budget next week"
            ),
            BuiltInExample(
                input: "Speaker 1: the office move is set for june. Speaker 2: do we need new desks? Speaker 1: no, we keep the current ones, but someone has to book the movers. Speaker 2: i can do that",
                output: "Summary: The office move is planned for June and the current desks are staying.\n\nDecisions:\n- Move the office in June\n- Keep the current desks\n\nAction items:\n- Book the movers (Speaker 2)"
            ),
        ],
        contextFromSelection: false,
        contextFromClipboard: false,
        contextFromActiveApplication: false
    )

    static let customPreset = ModePreset(
        type: .custom,
        key: "custom",
        name: "Custom",
        description: "Your own instructions and examples.",
        iconName: "slider.horizontal.3",
        instruction: nil,
        examples: [],
        contextFromSelection: false,
        contextFromClipboard: false,
        contextFromActiveApplication: false
    )
}
