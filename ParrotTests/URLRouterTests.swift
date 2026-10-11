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
        XCTAssertEqual(URLRoute(URL(string: "superwhisper://record")!), .ignored)
    }

    // MARK: - Spec Routes

    func testRecordRoutesMapToToggleStartAndStop() {
        XCTAssertEqual(URLRoute(URL(string: "parrot://record")!), .action("toggle", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://record/start")!), .action("start", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://record/stop")!), .action("stop", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://Record/Start/")!), .action("start", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://record?mode=Email")!), .action("toggle", mode: "Email"))
    }

    func testUnknownRecordPathDoesNothing() {
        XCTAssertEqual(URLRoute(URL(string: "parrot://record/pause")!), .action("record", mode: nil))
    }

    func testModeRouteSelectsByKey() {
        XCTAssertEqual(URLRoute(URL(string: "parrot://mode?key=email")!), .selectMode(key: "email"))
        XCTAssertEqual(URLRoute(URL(string: "parrot://mode?key=")!), .action("mode", mode: nil))
        XCTAssertEqual(URLRoute(URL(string: "parrot://mode?mode=Email")!), .action("mode", mode: "Email"),
                       "by name it only selects, like ?mode= on any action")
    }

    func testSettingsRoute() {
        XCTAssertEqual(URLRoute(URL(string: "parrot://settings")!), .settings)
    }

    func testModeKeyMatchesKeyNotName() {
        let email = Mode(key: "email", name: "Inbox")
        let notes = Mode(key: "Notes", name: "email")
        let modes = [notes, email]
        XCTAssertEqual(URLRouter.mode(forKey: "email", in: modes)?.id, email.id)
        XCTAssertEqual(URLRouter.mode(forKey: "notes", in: modes)?.id, notes.id, "case-insensitive fallback")
        XCTAssertNil(URLRouter.mode(forKey: "Inbox", in: modes))
    }
}
