import XCTest

@testable import Parrot

/// Tests the pure vocabulary replacement logic without touching the persisted
/// vocabulary file (via the static `VocabularyManager.apply(entries:to:)`).
final class VocabularyTests: XCTestCase {

    private func entries(_ pairs: [(String, String)]) -> [VocabularyEntry] {
        pairs.map { VocabularyEntry(original: $0.0, replacement: $0.1) }
    }

    private func apply(_ pairs: [(String, String)], to text: String) -> String {
        VocabularyManager.apply(entries: entries(pairs), to: text)
    }

    func testWholeWordReplacementOnly() {
        // Must not fire inside "concatenate" or "category".
        XCTAssertEqual(apply([("cat", "dog")], to: "concatenate the category"), "concatenate the category")
        XCTAssertEqual(apply([("cat", "dog")], to: "the cat sat"), "the dog sat")
    }

    func testCasePreservation() {
        XCTAssertEqual(apply([("github", "GitHub")], to: "push to github"), "push to GitHub")
        // All-caps match yields all-caps replacement.
        XCTAssertEqual(apply([("github", "GitHub")], to: "GITHUB down"), "GITHUB down")
        // Title-case match yields title-case replacement.
        XCTAssertEqual(apply([("github", "gitHub")], to: "Github outage"), "GitHub outage")
    }

    func testBoundaryAtStringEdges() {
        XCTAssertEqual(apply([("api", "API")], to: "api"), "API")
        XCTAssertEqual(apply([("api", "API")], to: "api first"), "API first")
        XCTAssertEqual(apply([("api", "API")], to: "the api"), "the API")
        // Not inside "apiary".
        XCTAssertEqual(apply([("api", "API")], to: "apiary"), "apiary")
    }

    func testPunctuationAdjacentIsWholeWord() {
        XCTAssertEqual(apply([("swift", "Swift")], to: "I love swift."), "I love Swift.")
        XCTAssertEqual(apply([("swift", "Swift")], to: "(swift)"), "(Swift)")
    }

    func testMultipleOccurrences() {
        XCTAssertEqual(apply([("cat", "dog")], to: "cat and cat"), "dog and dog")
    }
}

/// Tests the persisted vocabulary store against a temporary JSON file, so the
/// user's real vocabulary is never touched.
final class VocabularyStoreTests: XCTestCase {

    private var directory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        // A directory that does not exist yet, so saving must create it.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-vocab-tests-\(UUID().uuidString)", isDirectory: true)
        storageURL = directory.appendingPathComponent("vocabulary.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddedEntrySurvivesReloadAndApplies() {
        let manager = VocabularyManager(storageURL: storageURL)
        manager.addEntry(original: "git hub", replacement: "GitHub")

        let reloaded = VocabularyManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.entries.map(\.original), ["git hub"])
        XCTAssertEqual(reloaded.entries.map(\.replacement), ["GitHub"])
        XCTAssertEqual(reloaded.apply(to: "push to git hub"), "push to GitHub")
    }

    func testReplaceAllPersistsEditsAndRemovals() {
        let manager = VocabularyManager(storageURL: storageURL)
        let cat = VocabularyEntry(original: "cat", replacement: "dog")
        let api = VocabularyEntry(original: "api", replacement: "API")
        manager.replaceAll([cat, api])
        XCTAssertEqual(VocabularyManager(storageURL: storageURL).entries.count, 2)

        manager.replaceAll([api])
        let reloaded = VocabularyManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.entries.map(\.id), [api.id])
        XCTAssertEqual(reloaded.apply(to: "the cat and the api"), "the cat and the API")
    }

    func testDisabledEntryPersistsAndIsNotApplied() {
        let manager = VocabularyManager(storageURL: storageURL)
        manager.addEntry(original: "cat", replacement: "dog")
        var entry = manager.entries[0]
        entry.isEnabled = false
        manager.updateEntry(entry)

        let reloaded = VocabularyManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.entries.first?.isEnabled, false)
        XCTAssertEqual(reloaded.apply(to: "the cat sat"), "the cat sat")
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storageURL)
        XCTAssertTrue(VocabularyManager(storageURL: storageURL).entries.isEmpty)
    }

    /// The Vocabulary tab edits `AppState.vocabularyEntries`; those edits must
    /// land in the persisted store that find and replace reads.
    @MainActor
    func testAppStateEditsPersistThroughManager() {
        let state = AppState(vocabularyManager: VocabularyManager(storageURL: storageURL))
        state.vocabularyEntries.append(VocabularyEntry(original: "kube", replacement: "Kubernetes"))

        XCTAssertEqual(state.vocabularyManager.apply(to: "deploy to kube"), "deploy to Kubernetes")
        let reloaded = VocabularyManager(storageURL: storageURL)
        XCTAssertEqual(reloaded.entries.map(\.replacement), ["Kubernetes"])
    }
}
