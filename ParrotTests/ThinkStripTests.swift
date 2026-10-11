import XCTest

@testable import Parrot

/// Cleaning a model's reply: reasoning blocks, wrapper tags and fences.
final class ThinkStripTests: XCTestCase {

    func testThinkBlockIsRemoved() {
        XCTAssertEqual(OutputCleaner.clean("<think>The user wants commas.</think>Hello, world."), "Hello, world.")
        XCTAssertEqual(OutputCleaner.clean("<think>\nstep one\nstep two\n</think>\n\nHello."), "Hello.")
    }

    func testOtherReasoningTagsAndCaseAreRemoved() {
        XCTAssertEqual(OutputCleaner.clean("<thinking>plan</thinking>\nAnswer"), "Answer")
        XCTAssertEqual(OutputCleaner.clean("<THOUGHT>plan</THOUGHT>Answer"), "Answer")
        XCTAssertEqual(OutputCleaner.clean("<reasoning>x</reasoning>Answer"), "Answer")
    }

    func testBlockInTheMiddleIsRemoved() {
        XCTAssertEqual(OutputCleaner.clean("Answer<think>x</think> continues."), "Answer continues.")
    }

    func testMissingOpeningTagKeepsWhatFollowsTheClose() {
        XCTAssertEqual(OutputCleaner.clean("so the user means Tuesday</think>\nSee you Tuesday."), "See you Tuesday.")
    }

    func testUnclosedThinkMeansNoAnswer() {
        XCTAssertEqual(OutputCleaner.clean("<think>still going and going"), "")
        XCTAssertEqual(OutputCleaner.clean("Partial <think>and then reasoning"), "Partial")
    }

    func testLeadingThoughtLabelLineIsDropped() {
        XCTAssertEqual(OutputCleaner.clean("Thinking:\nHello there."), "Hello there.")
        XCTAssertEqual(OutputCleaner.clean("think\n\nHello there."), "Hello there.")
        XCTAssertEqual(OutputCleaner.clean("Thought"), "Thought", "a reply that is only the word stays")
        XCTAssertEqual(OutputCleaner.clean("Thought: buy milk\nand eggs"), "Thought: buy milk\nand eggs")
    }

    func testResponseWrapperKeepsItsInside() {
        XCTAssertEqual(OutputCleaner.clean("<response>Hi there.</response>"), "Hi there.")
        XCTAssertEqual(OutputCleaner.clean("Sure! Here it is: <response>Hi.</response>"), "Hi.")
        XCTAssertEqual(OutputCleaner.clean("<response>\nHi.\n</response>\n"), "Hi.")
        XCTAssertEqual(OutputCleaner.clean("<response>Hi, unclosed"), "Hi, unclosed")
    }

    func testThinkThenResponse() {
        XCTAssertEqual(OutputCleaner.clean("<think>plan</think>\n<response>Done.</response>"), "Done.")
    }

    func testGenericWrappersOnlyWhenTheyOpenTheReply() {
        XCTAssertEqual(OutputCleaner.clean("<output>Hi</output>"), "Hi")
        XCTAssertEqual(OutputCleaner.clean("<answer>42</answer>"), "42")
        XCTAssertEqual(OutputCleaner.clean("Wrap it in an <output> element"), "Wrap it in an <output> element")
    }

    func testWholeReplyFenceIsUnwrapped() {
        XCTAssertEqual(OutputCleaner.clean("```\nls -la\n```"), "ls -la")
        XCTAssertEqual(OutputCleaner.clean("```bash\ngit status\n```"), "git status")
        XCTAssertEqual(OutputCleaner.clean("Run ```ls``` now"), "Run ```ls``` now")
    }

    func testPlainTextIsOnlyTrimmed() {
        XCTAssertEqual(OutputCleaner.clean("  Hello, world.\n"), "Hello, world.")
        XCTAssertEqual(OutputCleaner.clean("Line one.\n\nLine two."), "Line one.\n\nLine two.")
    }
}
