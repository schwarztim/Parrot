import XCTest

@testable import Parrot

final class AppleScriptMacroTests: XCTestCase {

    // MARK: - Escaping

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(AppleScriptMacro.escape(#"He said "hi""#), #"He said \"hi\""#)
        XCTAssertEqual(AppleScriptMacro.escape(#"C:\path"#), #"C:\\path"#)
    }

    func testEscapesLineBreaksAndTabsOntoOneLine() {
        XCTAssertEqual(AppleScriptMacro.escape("a\nb\rc\td"), #"a\nb\rc\td"#)
        XCTAssertEqual(AppleScriptMacro.escape("a\r\nb"), #"a\r\nb"#)
    }

    func testLeavesOtherTextAlone() {
        XCTAssertEqual(AppleScriptMacro.escape("Café, 100% 👍"), "Café, 100% 👍")
    }

    // MARK: - Rendering

    func testReplacesEveryMacro() {
        let script = #"set a to "{{user_message}}"\#nset b to "{{user_message}}""#
        XCTAssertEqual(
            AppleScriptMacro.render(script: script, userMessage: #"x "y""#),
            #"set a to "x \"y\""\#nset b to "x \"y\"""#
        )
    }

    func testScriptWithoutMacroIsUnchanged() {
        XCTAssertEqual(AppleScriptMacro.render(script: "beep", userMessage: "hello"), "beep")
    }

    // MARK: - Runner (needs /usr/bin/osascript)

    private func requireOsascript() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"), "osascript not available")
    }

    func testRenderedScriptRoundTripsTheTextThroughOsascript() async throws {
        try requireOsascript()
        let message = "He said \"hi\"\nthen C:\\path\tdone"
        let source = AppleScriptMacro.render(script: "return \"{{user_message}}\"", userMessage: message)

        let printed = try await AppleScriptRunner(timeout: 10).run(source)
        XCTAssertEqual(printed, message)
    }

    func testScriptErrorThrowsWithItsMessage() async throws {
        try requireOsascript()
        do {
            _ = try await AppleScriptRunner(timeout: 10).run("error \"boom\"")
            XCTFail("expected a failure")
        } catch let failure as AppleScriptRunner.Failure {
            guard case .failed(let status, let message) = failure else {
                return XCTFail("unexpected \(failure)")
            }
            XCTAssertNotEqual(status, 0)
            XCTAssertTrue(message.contains("boom"), message)
        }
    }

    func testSlowScriptIsStoppedAtTheTimeout() async throws {
        try requireOsascript()
        let started = Date()
        do {
            _ = try await AppleScriptRunner(timeout: 0.5).run("delay 10")
            XCTFail("expected a timeout")
        } catch let failure as AppleScriptRunner.Failure {
            XCTAssertEqual(failure, .timedOut(0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
