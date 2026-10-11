import XCTest

@testable import Parrot

/// Spoken punctuation words become symbols, absorbing the recognizer's
/// stray commas, periods and spaces around them.
@MainActor
final class LiteralPunctuationTests: XCTestCase {

    private func apply(_ text: String) -> String {
        LiteralPunctuation.apply(text)
    }

    func testBasicWords() {
        XCTAssertEqual(apply("Hello comma world period"), "Hello, world.")
        XCTAssertEqual(apply("Is it ready question mark"), "Is it ready?")
        XCTAssertEqual(apply("Wow exclamation mark"), "Wow!")
        XCTAssertEqual(apply("one semicolon two colon three"), "one; two: three")
    }

    func testStrayPunctuationAroundTheWordIsAbsorbed() {
        XCTAssertEqual(apply("Hello, comma, world. Period."), "Hello, world.")
        XCTAssertEqual(apply("Done. Period."), "Done.")
    }

    func testFirstLetterEitherCaseAndHyphenVariants() {
        XCTAssertEqual(apply("Stop Period"), "Stop.")
        XCTAssertEqual(apply("a semi-colon b"), "a; b")
        XCTAssertEqual(apply("first new-line second"), "first\nsecond")
    }

    func testNewLineAndParagraph() {
        XCTAssertEqual(apply("Dear Sam, new line, thanks."), "Dear Sam\nthanks.")
        XCTAssertEqual(apply("One. New paragraph. Two."), "One\n\nTwo.")
    }

    func testSlashAndDashJoinTheirNeighbors() {
        XCTAssertEqual(apply("and slash or"), "and/or")
        XCTAssertEqual(apply("Monday dash Friday"), "Monday-Friday")
    }

    func testWordsInsideLongerWordsAreLeftAlone() {
        XCTAssertEqual(apply("The periodic table"), "The periodic table")
        XCTAssertEqual(apply("A comma-separated list"), "A comma-separated list")
        XCTAssertEqual(apply("SHOUTING PERIOD"), "SHOUTING PERIOD")
    }

    func testStageAppliesOnlyWhenTheModeAsks() async throws {
        let env = ASRTestEnvironment()
        defer { env.tearDown() }
        let stage = TranscriptCleanupStage(services: env.services)

        let plain = env.session(samples: ASRFixture.zeros(seconds: 2), mode: Mode(name: "Plain"))
        plain.text = "Hello comma world"
        _ = try await stage.run(plain)
        XCTAssertEqual(plain.text, "Hello comma world")

        let literal = env.session(
            samples: ASRFixture.zeros(seconds: 2), mode: Mode(name: "Literal", literalPunctuation: true)
        )
        literal.text = "Hello comma world"
        literal.rawTranscript = literal.text
        _ = try await stage.run(literal)
        XCTAssertEqual(literal.text, "Hello, world")
        XCTAssertEqual(literal.rawTranscript, "Hello comma world")
    }
}
