import XCTest

@testable import Parrot

/// How URLRouter sorts the URLs handed to the app.
final class URLRouterTests: XCTestCase {

    func testParrotActionsKeepTheirHostAndMode() {
        XCTAssertEqual(URLRoute(URL(string: "parrot://toggle")!), .action("toggle", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://Start?mode=Email")!), .action("start", mode: "Email"))
        XCTAssertEqual(URLRoute(URL(string: "parrot://stop")!), .action("stop", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://cancel")!), .action("cancel", mode: nil))
    }

    func testAgentHostsForwardToTheAgent() {
        let url = URL(string: "parrot://agent-update?id=1")!
        XCTAssertEqual(URLRoute(url), .agent(url))
        let upper = URL(string: "parrot://Agent-Reply")!
        XCTAssertEqual(URLRoute(upper), .agent(upper))
    }

    func testFileURLsForwardToTranscription() {
        let file = URL(fileURLWithPath: "/tmp/memo.wav")
        XCTAssertEqual(URLRoute(file), .file(file))
    }

    func testOtherSchemesAreIgnored() {
        XCTAssertEqual(URLRoute(URL(string: "https://example.com/toggle")!), .ignored)
    }
}
