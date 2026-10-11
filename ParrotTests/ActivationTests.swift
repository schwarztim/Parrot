import XCTest

@testable import Parrot

/// Mode auto-activation: website rules, app rules and their precedence.
final class ActivationTests: XCTestCase {

    private func mode(_ name: String, sites: [String] = [], apps: [String]? = nil) -> Mode {
        Mode(name: name, appBundleIDs: apps, activationSites: sites)
    }

    // MARK: - Site Matching

    func testSiteMatchesItsHostAndSubdomains() {
        XCTAssertTrue(ModeActivation.siteMatches("example.com", url: "https://example.com/inbox"))
        XCTAssertTrue(ModeActivation.siteMatches("example.com", url: "https://docs.example.com/a"))
        XCTAssertTrue(ModeActivation.siteMatches("example.com", url: "https://a.b.example.com"))
    }

    func testSiteNeverMatchesASimilarLookingHost() {
        XCTAssertFalse(ModeActivation.siteMatches("example.com", url: "https://notexample.com"))
        XCTAssertFalse(ModeActivation.siteMatches("example.com", url: "https://example.com.evil.net"))
        XCTAssertFalse(ModeActivation.siteMatches("mail.example.com", url: "https://example.com"))
    }

    func testWWWSchemeAndCaseAreIgnored() {
        XCTAssertTrue(ModeActivation.siteMatches("www.Example.com", url: "https://example.com"))
        XCTAssertTrue(ModeActivation.siteMatches("https://example.com/", url: "http://WWW.EXAMPLE.COM/x"))
        XCTAssertTrue(ModeActivation.siteMatches("example.com", url: "example.com/path"))
    }

    func testSiteWithPathNeedsThatPathPrefix() {
        let site = "docs.google.com/document"
        XCTAssertTrue(ModeActivation.siteMatches(site, url: "https://docs.google.com/document/d/123/edit"))
        XCTAssertTrue(ModeActivation.siteMatches(site, url: "https://docs.google.com/document"))
        XCTAssertFalse(ModeActivation.siteMatches(site, url: "https://docs.google.com/spreadsheets/d/1"))
        XCTAssertFalse(ModeActivation.siteMatches(site, url: "https://docs.google.com/documentation"))
    }

    func testEmptyOrHostlessInputNeverMatches() {
        XCTAssertFalse(ModeActivation.siteMatches("", url: "https://example.com"))
        XCTAssertFalse(ModeActivation.siteMatches("example.com", url: ""))
        XCTAssertNil(ModeActivation.mode(forURL: nil, in: [mode("A", sites: ["example.com"])]))
    }

    func testNormalizedSiteDropsSchemeWWWPortAndQuery() {
        XCTAssertEqual(ModeActivation.normalizedSite("https://www.GitHub.com:443/Org/?tab=1"), "github.com/org")
        XCTAssertEqual(ModeActivation.normalizedSite("mail.google.com"), "mail.google.com")
        XCTAssertNil(ModeActivation.normalizedSite("   "))
    }

    func testSiteOnlyKeepsSchemeAndHost() {
        XCTAssertEqual(ModeActivation.siteOnly("https://Mail.Google.com/mail/u/0/#inbox?x=1"), "https://mail.google.com")
        XCTAssertEqual(ModeActivation.siteOnly("example.com/secret-doc"), "https://example.com")
    }

    // MARK: - Precedence

    func testMostSpecificSiteWins() {
        let broad = mode("Google", sites: ["google.com"])
        let mail = mode("Gmail", sites: ["mail.google.com"])
        let found = ModeActivation.mode(forURL: "https://mail.google.com/mail/u/0", in: [broad, mail])
        XCTAssertEqual(found?.name, "Gmail")
    }

    func testEqualSitesGoToTheEarlierMode() {
        let first = mode("First", sites: ["example.com"])
        let second = mode("Second", sites: ["example.com"])
        XCTAssertEqual(ModeActivation.mode(forURL: "https://example.com", in: [first, second])?.name, "First")
    }

    func testSiteBeatsAppAndAppBeatsFallback() {
        let fallback = mode("Last selected")
        let browser = mode("Browser", apps: ["com.apple.Safari"])
        let github = mode("GitHub", sites: ["github.com"])
        let modes = [fallback, browser, github]

        var context = DictationContext(appName: "Safari", bundleID: "com.apple.safari")
        context.browserURL = "https://github.com/org/repo/pull/1"
        XCTAssertEqual(ModeActivation.resolve(modes: modes, context: context, fallback: fallback).name, "GitHub")

        context.browserURL = "https://news.example.org"
        XCTAssertEqual(ModeActivation.resolve(modes: modes, context: context, fallback: fallback).name, "Browser")

        let other = DictationContext(appName: "Notes", bundleID: "com.apple.Notes")
        XCTAssertEqual(ModeActivation.resolve(modes: modes, context: other, fallback: fallback).name, "Last selected")
        XCTAssertEqual(ModeActivation.resolve(modes: modes, context: nil, fallback: fallback).name, "Last selected")
    }

    func testAppMatchIsCaseInsensitive() {
        let mail = mode("Mail", apps: ["com.apple.mail"])
        XCTAssertEqual(ModeActivation.mode(forBundleID: "COM.Apple.Mail", in: [mail])?.name, "Mail")
        XCTAssertNil(ModeActivation.mode(forBundleID: "", in: [mail]))
    }

    // MARK: - Through ModeManager

    func testModeManagerResolvesSitesThenAppsThenSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-activation-\(UUID().uuidString)", isDirectory: true)
        let suite = "ParrotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        let manager = ModeManager(paths: AppPaths(root: root), defaults: defaults)
        var email = try XCTUnwrap(manager.mode(forKey: "email"))
        email.activationSites = ["mail.google.com"]
        manager.updateMode(email)
        var message = try XCTUnwrap(manager.mode(forKey: "message"))
        message.appBundleIDs = ["com.tinyspeck.slackmacgap"]
        manager.updateMode(message)

        var gmail = DictationContext(appName: "Chrome", bundleID: "com.google.Chrome")
        gmail.browserURL = "https://mail.google.com/mail/u/0/#inbox"
        XCTAssertEqual(manager.resolveMode(context: gmail).key, "email")
        XCTAssertTrue(manager.hasSiteRules)

        let slack = DictationContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(manager.resolveMode(context: slack).key, "message")

        let notes = DictationContext(appName: "Notes", bundleID: "com.apple.Notes")
        XCTAssertEqual(manager.resolveMode(context: notes).key, "super")
        XCTAssertEqual(manager.selectedMode.key, "super", "resolving never changes the selection")
    }
}
