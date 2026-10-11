import XCTest

@testable import Parrot

/// Parrot's own app catalog: the hand map, Info.plist categories, websites
/// and the activation groups. Uses a temporary fake app bundle.
final class AppCatalogTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-appcatalog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A folder shaped like an app bundle with the given Info.plist keys.
    private func makeApp(_ name: String, info: [String: Any]) throws -> URL {
        let app = tempDir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    // MARK: - Hand Map

    func testCommonAppsHaveATextFormat() {
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.tinyspeck.slackmacgap")?.inputFormat, .chatMessage)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.mail")?.inputFormat, .email)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.dt.Xcode")?.inputFormat, .code)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.googlecode.iterm2")?.inputFormat, .terminal)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.Notes")?.inputFormat, .document)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.mail")?.category, "Email")
    }

    func testBundleIDsMatchIgnoringCaseAndJetBrainsByPrefix() {
        XCTAssertEqual(AppCatalog.entry(bundleID: "COM.APPLE.MAIL")?.inputFormat, .email)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.jetbrains.intellij")?.inputFormat, .code)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.jetbrains.pycharm.ce")?.category, "Code Editor")
    }

    func testUnknownAppWithoutBundleIsNil() {
        XCTAssertNil(AppCatalog.entry(bundleID: "com.example.unknown"))
        XCTAssertNil(AppCatalog.entry(bundleID: nil))
    }

    // MARK: - Info.plist

    func testDeclaredCategoryComesFromInfoPlist() throws {
        let app = try makeApp("Tool", info: [
            "CFBundleIdentifier": "com.example.tool",
            "LSApplicationCategoryType": "public.app-category.developer-tools",
        ])
        XCTAssertEqual(AppCatalog.declaredCategory(appURL: app), "public.app-category.developer-tools")
        let entry = AppCatalog.entry(bundleID: "com.example.tool", appURL: app)
        XCTAssertEqual(entry?.category, "Developer Tools")
        XCTAssertEqual(entry?.inputFormat, .code)
    }

    func testHandMapWinsOverInfoPlist() throws {
        let app = try makeApp("Mail", info: ["LSApplicationCategoryType": "public.app-category.productivity"])
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.mail", appURL: app)?.inputFormat, .email)
    }

    func testCategoryMapping() {
        XCTAssertEqual(AppCatalog.entry(forLSCategory: "public.app-category.social-networking")?.inputFormat, .chatMessage)
        XCTAssertEqual(AppCatalog.entry(forLSCategory: "public.app-category.productivity")?.category, "Productivity")
        XCTAssertEqual(AppCatalog.entry(forLSCategory: "public.app-category.puzzle-games")?.category, "Games")
        XCTAssertNil(AppCatalog.entry(forLSCategory: "public.app-category.made-up"))
    }

    func testAppWithoutCategoryOrPlistIsNil() throws {
        let app = try makeApp("Plain", info: ["CFBundleIdentifier": "com.example.plain"])
        XCTAssertNil(AppCatalog.entry(bundleID: "com.example.plain", appURL: app))
        XCTAssertNil(AppCatalog.declaredCategory(appURL: tempDir.appendingPathComponent("Missing.app")))
    }

    // MARK: - Websites

    func testKnownSiteDecidesTheFormatInABrowser() {
        let gmail = AppCatalog.entry(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(gmail?.inputFormat, .email)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.Safari", url: "https://docs.google.com/document/d/1")?.inputFormat, .document)
        XCTAssertEqual(AppCatalog.entry(bundleID: "com.apple.Safari", url: "https://chatgpt.com/c/123")?.category, "AI Chat")
    }

    func testUnknownSiteFallsBackToTheBrowser() {
        let entry = AppCatalog.entry(bundleID: "com.apple.Safari", url: "https://news.example.org")
        XCTAssertEqual(entry?.category, "Web Browser")
        XCTAssertNil(entry?.inputFormat)
    }

    func testSiteMatchingUsesWholeLabels() {
        XCTAssertEqual(AppCatalog.siteEntry(forHost: "www.reddit.com")?.category, "Social Media")
        XCTAssertNil(AppCatalog.siteEntry(forHost: "notreddit.com"))
    }

    // MARK: - Activation Groups

    func testActivationGroupsBundleAppsAndSites() {
        let groups = AppCatalog.activationCategories
        XCTAssertEqual(groups.map(\.group), ActivationCategory.Group.allCases)
        XCTAssertTrue(groups.allSatisfy { !$0.name.isEmpty && !$0.symbol.isEmpty })

        let email = groups.first { $0.group == .email }
        XCTAssertTrue(email?.bundleIDs.contains("com.apple.mail") == true)
        XCTAssertTrue(email?.sites.contains("mail.google.com") == true)
        let terminal = groups.first { $0.group == .terminal }
        XCTAssertTrue(terminal?.sites.isEmpty == true)
        XCTAssertTrue(terminal?.bundleIDs.contains("com.apple.Terminal") == true)
    }

    func testFormatsHavePromptNames() {
        XCTAssertEqual(TextInputFormat.allCases.map(\.promptName), ["chat message", "email", "code", "terminal command", "document text"])
    }

    // MARK: - Browsers

    func testBrowserScriptsPerFamily() {
        XCTAssertTrue(BrowserURLReader.isBrowser("com.apple.Safari"))
        XCTAssertTrue(BrowserURLReader.isBrowser("company.thebrowser.Browser"))
        XCTAssertTrue(BrowserURLReader.isBrowser("org.mozilla.firefox"))
        XCTAssertFalse(BrowserURLReader.isBrowser("com.apple.mail"))
        XCTAssertFalse(BrowserURLReader.isBrowser(nil))

        XCTAssertEqual(
            BrowserURLReader.script(for: "com.apple.Safari"),
            "tell application id \"com.apple.Safari\" to return URL of front document"
        )
        XCTAssertEqual(
            BrowserURLReader.script(for: "com.brave.Browser"),
            "tell application id \"com.brave.Browser\" to return URL of active tab of front window"
        )
        XCTAssertNil(BrowserURLReader.script(for: "org.mozilla.firefox"), "Firefox is read through Accessibility")
    }

    func testOnlyWebAddressesAreAccepted() {
        XCTAssertEqual(BrowserURLReader.cleaned(" https://example.com/a \n"), "https://example.com/a")
        XCTAssertEqual(BrowserURLReader.cleaned("file:///Users/me/page.html"), "file:///Users/me/page.html")
        XCTAssertNil(BrowserURLReader.cleaned("missing value"))
        XCTAssertNil(BrowserURLReader.cleaned("javascript:alert(1)"))
        XCTAssertNil(BrowserURLReader.cleaned(""))
        XCTAssertNil(BrowserURLReader.cleaned(nil))
    }
}
