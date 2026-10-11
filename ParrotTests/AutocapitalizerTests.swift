import XCTest

@testable import Parrot

final class AutocapitalizerTests: XCTestCase {

    private func apply(_ text: String, before: String, after: String = "") -> String {
        Autocapitalizer.apply(text, context: CursorContext(before: before, after: after))
    }

    // MARK: - Case

    func testNoContextLeavesTextUnchanged() {
        XCTAssertEqual(Autocapitalizer.apply("hello there", context: nil), "hello there")
    }

    func testEmptyFieldCapitalizes() {
        XCTAssertEqual(apply("hello there", before: ""), "Hello there")
    }

    func testAfterSentenceEndCapitalizes() {
        XCTAssertEqual(apply("then we left", before: "It rained. "), "Then we left")
        XCTAssertEqual(apply("really", before: "Why? "), "Really")
        XCTAssertEqual(apply("wow", before: "Stop! "), "Wow")
    }

    func testAfterNewlineCapitalizes() {
        XCTAssertEqual(apply("second line", before: "First line,\n"), "Second line")
    }

    func testClosingQuoteAfterSentenceEndCapitalizes() {
        XCTAssertEqual(apply("then he left", before: "He said \"Done.\" "), "Then he left")
    }

    func testMidSentenceLowercases() {
        XCTAssertEqual(apply("Sat down", before: "The cat "), "sat down")
        XCTAssertEqual(apply("And then", before: "We went home, "), "and then")
    }

    func testMidSentenceKeepsPronounIAndAcronyms() {
        XCTAssertEqual(apply("I think so", before: "Well, "), "I think so")
        XCTAssertEqual(apply("I'm sure", before: "Well, "), "I'm sure")
        XCTAssertEqual(apply("NASA said", before: "Yesterday "), "NASA said")
        XCTAssertEqual(apply("McDonald came", before: "Then "), "McDonald came")
    }

    func testLeadingQuoteIsSkippedToFindTheFirstLetter() {
        XCTAssertEqual(apply("\"hello\" she said", before: ""), "\"Hello\" she said")
    }

    func testDigitsAreLeftAlone() {
        XCTAssertEqual(apply("42 apples", before: ""), "42 apples")
    }

    // MARK: - Leading Space

    func testLeadingSpaceRightAfterAWord() {
        XCTAssertEqual(apply("and more", before: "word"), " and more")
        XCTAssertEqual(apply("Next one", before: "Done."), " Next one")
    }

    func testNoLeadingSpaceAfterWhitespaceOrOpenerOrAtStart() {
        XCTAssertEqual(apply("and more", before: "word "), "and more")
        XCTAssertEqual(apply("see above", before: "Note ("), "see above")
        XCTAssertEqual(apply("hello", before: ""), "Hello")
    }

    func testNoLeadingSpaceBeforeAttachingPunctuation() {
        XCTAssertEqual(apply(", and then", before: "word"), ", and then")
        XCTAssertEqual(apply(".", before: "word"), ".")
    }

    // MARK: - Context From Field Text

    func testContextFromTextAndCaret() throws {
        let context = try XCTUnwrap(CursorContext(text: "Hello world", selection: NSRange(location: 5, length: 0)))
        XCTAssertEqual(context.characterBefore, "o")
        XCTAssertEqual(context.characterAfter, " ")
        XCTAssertEqual(context.lastNonWhitespaceBefore, "o")
        XCTAssertFalse(context.newlineBeforeCaret)
    }

    func testContextUsesTheSelectionEdges() throws {
        // "world" selected: the dictation replaces it.
        let context = try XCTUnwrap(CursorContext(text: "Hello world!", selection: NSRange(location: 6, length: 5)))
        XCTAssertEqual(context.characterBefore, " ")
        XCTAssertEqual(context.characterAfter, "!")
        XCTAssertEqual(context.lastNonWhitespaceBefore, "o")
    }

    func testContextAtFieldStartAndAfterNewline() throws {
        let start = try XCTUnwrap(CursorContext(text: "abc", selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(start.characterBefore)
        XCTAssertNil(start.lastNonWhitespaceBefore)
        XCTAssertTrue(Autocapitalizer.isSentenceStart(start))

        let newline = try XCTUnwrap(CursorContext(text: "One,\n  ", selection: NSRange(location: 7, length: 0)))
        XCTAssertEqual(newline.lastNonWhitespaceBefore, ",")
        XCTAssertTrue(newline.newlineBeforeCaret)
    }

    func testContextCountsUTF16LikeAccessibility() throws {
        // The emoji is two UTF-16 units.
        let context = try XCTUnwrap(CursorContext(text: "👍 ok", selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(context.characterBefore, "👍")
        XCTAssertEqual(context.characterAfter, " ")
    }

    func testSelectionOutsideTheTextGivesNoContext() {
        XCTAssertNil(CursorContext(text: "abc", selection: NSRange(location: 5, length: 0)))
        XCTAssertNil(CursorContext(text: "abc", selection: NSRange(location: NSNotFound, length: 0)))
    }
}
