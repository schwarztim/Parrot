import XCTest

@testable import Parrot

/// Tests ModeManager and Mode using injected temp storage and an isolated
/// UserDefaults suite, so neither the real modes.json nor the real defaults
/// are touched.
final class ModeManagerTests: XCTestCase {

    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-modetests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "ParrotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager() -> ModeManager {
        ModeManager(storageURL: tempDir.appendingPathComponent("modes.json"), defaults: defaults)
    }

    // MARK: - Per-App Auto-Mode

    func testModeForBundleIDMatches() {
        let m = makeManager()
        var mode = Mode(name: "Mail Mode")
        mode.appBundleIDs = ["com.apple.mail"]
        m.replaceAll([Mode.defaultMode, mode])
        XCTAssertEqual(m.mode(forBundleID: "com.apple.mail")?.name, "Mail Mode")
    }

    func testModeForBundleIDCaseInsensitive() {
        let m = makeManager()
        var mode = Mode(name: "Mail Mode")
        mode.appBundleIDs = ["com.apple.mail"]
        m.replaceAll([mode])
        XCTAssertEqual(m.mode(forBundleID: "COM.Apple.Mail")?.name, "Mail Mode")
    }

    func testModeForBundleIDNilAndUnknownReturnNil() {
        let m = makeManager()
        m.replaceAll([Mode.defaultMode])
        XCTAssertNil(m.mode(forBundleID: nil))
        XCTAssertNil(m.mode(forBundleID: "com.unknown.app"))
    }

    func testFirstMatchWinsOnDuplicateClaims() {
        let m = makeManager()
        var a = Mode(name: "A"); a.appBundleIDs = ["com.x"]
        var b = Mode(name: "B"); b.appBundleIDs = ["com.x"]
        m.replaceAll([a, b])
        XCTAssertEqual(m.mode(forBundleID: "com.x")?.name, "A")
    }

    func testAppBundleIDsRoundTripThroughPersistence() {
        let url = tempDir.appendingPathComponent("modes.json")
        let first = ModeManager(storageURL: url, defaults: defaults)
        var mode = Mode(name: "Slack"); mode.appBundleIDs = ["com.tinyspeck.slackmacgap"]
        first.replaceAll([Mode.defaultMode, mode])

        let second = ModeManager(storageURL: url, defaults: defaults)
        XCTAssertEqual(second.mode(forBundleID: "com.tinyspeck.slackmacgap")?.name, "Slack")
    }

    // MARK: - Duplicate Key Cleanup

    func testRemovesRetiredLowercaseSelectedModeKey() {
        defaults.set("stale-value", forKey: "parrot.selectedModeID")
        _ = makeManager()
        XCTAssertNil(defaults.string(forKey: "parrot.selectedModeID"))
    }

    // MARK: - Legacy Decoding

    func testLegacyModesJSONWithLanguageFieldsDecodes() throws {
        // JSON written before language/voiceModelVersion were removed and before
        // appBundleIDs existed.
        let legacy = """
            [{"id":"\(UUID().uuidString)","name":"Old","description":"",
              "voiceModelVersion":"v3","language":"auto","isDefault":true}]
            """
        let url = tempDir.appendingPathComponent("modes.json")
        try Data(legacy.utf8).write(to: url)
        let m = ModeManager(storageURL: url, defaults: defaults)
        XCTAssertEqual(m.selectedMode.name, "Old")
        XCTAssertNil(m.selectedMode.appBundleIDs)
    }
}
