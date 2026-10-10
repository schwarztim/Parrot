import XCTest
@testable import Parrot

/// Guards the user's real data: inside a test run every default storage
/// location must resolve to a throwaway folder, never Application Support.
final class TestIsolationTests: XCTestCase {

    private var realRoot: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot", isDirectory: true).standardizedFileURL.path
    }

    func testDefaultRootIsNotTheRealParrotFolder() {
        XCTAssertTrue(AppPaths.isRunningTests)
        XCTAssertNotEqual(AppPaths.defaultRoot.standardizedFileURL.path, realRoot)
        XCTAssertNotEqual(AppPaths().root.standardizedFileURL.path, realRoot)
    }

    func testManagerDefaultsStayOutOfTheRealParrotFolder() {
        for url in [HistoryStore.defaultURL(), VocabularyManager.defaultStorageURL(), ModeManager.defaultStorageURL] {
            XCTAssertFalse(url.standardizedFileURL.path.hasPrefix(realRoot + "/"), url.path)
        }
    }
}
