import XCTest

@testable import Parrot

/// AppPaths builds every location from an injectable root.
final class AppPathsTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPathsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testProductionRootIsApplicationSupportParrot() {
        let root = AppPaths.productionRoot
        XCTAssertEqual(root.lastPathComponent, "Parrot")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Application Support")
        // Inside tests the default root is a throwaway folder instead.
        XCTAssertNotEqual(AppPaths().root, root)
    }

    func testLayoutUnderAnInjectedRoot() {
        let paths = AppPaths(root: root)
        XCTAssertEqual(paths.recordings, root.appendingPathComponent("recordings", isDirectory: true))
        XCTAssertEqual(paths.modes, root.appendingPathComponent("modes", isDirectory: true))
        XCTAssertEqual(paths.agentInbox.path, root.appendingPathComponent("agent/inbox").path)
        XCTAssertEqual(paths.historyDatabase.lastPathComponent, "parrot.db")
        XCTAssertEqual(paths.vocabularyFile.lastPathComponent, "vocabulary.json")
        XCTAssertEqual(paths.legacyModesFile.lastPathComponent, "modes.json")
    }

    func testRecordingFolderIsNamedByUnixSeconds() {
        let paths = AppPaths(root: root)
        let folder = paths.recordingFolder(startedAt: Date(timeIntervalSince1970: 1_760_000_000.75))
        XCTAssertEqual(folder.lastPathComponent, "1760000000")
        XCTAssertEqual(folder.deletingLastPathComponent(), paths.recordings)
        XCTAssertEqual(paths.recordingAudio(in: folder).lastPathComponent, "output.wav")
        XCTAssertEqual(paths.recordingMeta(in: folder).lastPathComponent, "meta.json")
    }

    func testEnsureDirectoryCreatesParents() throws {
        let paths = AppPaths(root: root)
        let inbox = try paths.ensureDirectory(paths.agentInbox)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
