import XCTest

@testable import Parrot

/// Vocabulary CSV parsing, its error messages, the merge rules shared with
/// the Superwhisper importer, and the replacement passes around refinement.
final class CSVImportTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Parsing

    func testWordsAndReplacements() throws {
        let entries = try VocabularyCSV.entries(fromCSV: "word,replacement\nKubernetes,\nbtw,by the way\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isWord)
        XCTAssertEqual(entries[0].original, "Kubernetes")
        XCTAssertEqual(entries[0].replacement, "Kubernetes", "a word is boosted through its replacement")
        XCTAssertFalse(entries[1].isWord)
        XCTAssertEqual(entries[1].replacement, "by the way")
    }

    func testWordColumnOnlyAndAnyOrder() throws {
        XCTAssertEqual(try VocabularyCSV.entries(fromCSV: "Word\nParrot\nGitHub").map(\.original), ["Parrot", "GitHub"])
        let swapped = try VocabularyCSV.entries(fromCSV: "replacement,word\nhello world,hw\n")
        XCTAssertEqual(swapped.first?.original, "hw")
        XCTAssertEqual(swapped.first?.replacement, "hello world")
    }

    func testQuotedFieldsCRLFAndBOM() throws {
        let csv = "\u{FEFF}word,replacement\r\n\"my sig\",\"Best,\nTim \"\"T\"\"\"\r\nplain,\r\n"
        let entries = try VocabularyCSV.entries(fromCSV: csv)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].original, "my sig")
        XCTAssertEqual(entries[0].replacement, "Best,\nTim \"T\"")
        XCTAssertTrue(entries[1].isWord)
    }

    func testBlankRowsAndEmptyWordsAreSkipped() throws {
        let entries = try VocabularyCSV.entries(fromCSV: "word,replacement\n\n,orphan\nkept,\n,\n")
        XCTAssertEqual(entries.map(\.original), ["kept"])
    }

    // MARK: - Errors

    func testErrors() {
        XCTAssertThrowsError(try VocabularyCSV.entries(fromCSV: "")) {
            XCTAssertEqual($0 as? VocabularyCSV.ImportError, .empty)
        }
        XCTAssertThrowsError(try VocabularyCSV.entries(fromCSV: "term,replacement\na,b")) {
            XCTAssertEqual($0 as? VocabularyCSV.ImportError, .missingWordHeader)
        }
        XCTAssertThrowsError(try VocabularyCSV.entries(fromCSV: "word,replacement,notes\na,b,c")) {
            XCTAssertEqual($0 as? VocabularyCSV.ImportError, .tooManyColumns)
            XCTAssertEqual($0.localizedDescription, "The CSV can only have word and replacement columns.")
        }
        XCTAssertThrowsError(try VocabularyCSV.entries(fromCSV: "word\na,b")) {
            XCTAssertEqual($0 as? VocabularyCSV.ImportError, .tooManyColumns)
        }
        XCTAssertThrowsError(try VocabularyCSV.entries(fromCSV: "word,replacement\n,\n")) {
            XCTAssertEqual($0 as? VocabularyCSV.ImportError, .nothingImported)
            XCTAssertTrue($0.localizedDescription.hasPrefix("Nothing imported"))
        }
    }

    func testFileChecks() throws {
        let csv = dir.appendingPathComponent("list.csv")
        try Data("word\nParrot\n".utf8).write(to: csv)
        let txt = dir.appendingPathComponent("list.txt")
        try Data("word\nParrot\n".utf8).write(to: txt)

        XCTAssertEqual(try VocabularyCSV.entries(fromFile: csv).count, 1)
        XCTAssertThrowsError(try VocabularyCSV.validate([txt])) { XCTAssertEqual($0 as? VocabularyCSV.ImportError, .notCSV) }
        XCTAssertThrowsError(try VocabularyCSV.validate([dir])) { XCTAssertEqual($0 as? VocabularyCSV.ImportError, .folder) }
        XCTAssertThrowsError(try VocabularyCSV.validate([csv, csv])) { XCTAssertEqual($0 as? VocabularyCSV.ImportError, .multipleFiles) }
        XCTAssertThrowsError(try VocabularyCSV.entries(fromFile: dir.appendingPathComponent("missing.csv"))) {
            XCTAssertEqual($0 as? VocabularyCSV.ImportError, .unreadable)
        }
    }

    func testExampleCSVImportsCleanly() throws {
        let entries = try VocabularyCSV.entries(fromCSV: VocabularyCSV.exampleCSV)
        XCTAssertGreaterThanOrEqual(entries.filter(\.isWord).count, 2)
        XCTAssertGreaterThanOrEqual(entries.filter { !$0.isWord }.count, 1)
    }

    // MARK: - Merge

    func testMergeDedupesAndReplacementWins() {
        let existing = [VocabularyEntry.word("Parrot"), VocabularyEntry(original: "btw", replacement: "by the way")]
        let incoming = [
            VocabularyEntry.word("parrot"),                                // duplicate word
            VocabularyEntry(original: "BTW", replacement: "between"),      // existing replacement wins
            VocabularyEntry.word("Kubernetes"),                            // new word
            VocabularyEntry(original: "kubernetes", replacement: "K8s"),   // upgrades the word just added
            VocabularyEntry(original: "gh", replacement: "GitHub"),        // new replacement
        ]
        let result = VocabularyMerge.merge(existing: existing, incoming: incoming)

        XCTAssertEqual(result.entries.count, 4)
        XCTAssertEqual(result.wordsAdded, 1)
        XCTAssertEqual(result.replacementsAdded, 1)
        XCTAssertEqual(result.upgraded, 1)
        XCTAssertEqual(result.duplicates, 2)
        XCTAssertEqual(result.entries.first { $0.original == "btw" }?.replacement, "by the way")
        XCTAssertEqual(result.entries.first { $0.original.lowercased() == "kubernetes" }?.replacement, "K8s")
    }

    func testManagerMergePersists() throws {
        let url = dir.appendingPathComponent("vocabulary.json")
        let manager = VocabularyManager(storageURL: url)
        manager.merge([.word("Parrot"), VocabularyEntry(original: "btw", replacement: "by the way")])
        let reloaded = VocabularyManager(storageURL: url)
        XCTAssertEqual(reloaded.words.map(\.original), ["Parrot"])
        XCTAssertEqual(reloaded.replacements.map(\.original), ["btw"])
    }

    // MARK: - Replacement Passes

    func testWordsNeverRewriteText() {
        let entries = [VocabularyEntry.word("github"), VocabularyEntry(original: "", replacement: "x"),
                       VocabularyEntry(original: "legacy", replacement: "")]
        XCTAssertEqual(VocabularyManager.apply(entries: entries, to: "Push to GitHub, legacy code"), "Push to GitHub, legacy code")
    }

    func testPostRefinePassSkipsSelfContainingReplacements() {
        let entries = [VocabularyEntry(original: "Parrot", replacement: "Parrot app"),
                       VocabularyEntry(original: "btw", replacement: "by the way")]
        let first = VocabularyManager.apply(entries: entries, to: "Parrot rocks btw")
        XCTAssertEqual(first, "Parrot app rocks by the way")
        let second = VocabularyManager.apply(entries: entries, to: first, skippingSelfContaining: true)
        XCTAssertEqual(second, "Parrot app rocks by the way", "no doubling on the second pass")
        XCTAssertEqual(VocabularyManager.apply(entries: entries, to: "btw again", skippingSelfContaining: true), "by the way again")
    }

    @MainActor
    func testPostRefineStageRunsOnlyAfterRefinement() async throws {
        let manager = VocabularyManager(storageURL: dir.appendingPathComponent("vocabulary.json"))
        manager.merge([VocabularyEntry(original: "btw", replacement: "by the way")])
        let services = AppServices(vocabulary: manager)
        let stage = PostRefineReplacementsStage(services: services)

        let plain = DictationSession(trigger: .menu)
        plain.text = "btw"
        _ = try await stage.run(plain)
        XCTAssertEqual(plain.text, "btw", "no refinement, no second pass")

        let refined = DictationSession(trigger: .menu)
        refined.text = "Okay btw"
        refined.llmText = "Okay btw"
        _ = try await stage.run(refined)
        XCTAssertEqual(refined.text, "Okay by the way")
    }
}
