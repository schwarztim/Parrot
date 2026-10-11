import XCTest

@testable import Parrot

/// Opt-in proof against the operator's real Superwhisper folder.
///
/// Runs only with `PARROT_SW_DRYRUN=1`. Points the importer, in dry-run
/// mode, at `~/Documents/superwhisper` (resolved through Superwhisper's own
/// `appFolderDirectory` preference, read-only) and prints counts only:
/// never a transcript, prompt, vocabulary word or replacement. Nothing is
/// written there or anywhere else (no history database, no vocabulary or
/// mode targets).
@MainActor
final class ImporterRealDryRun: XCTestCase {

    func testRealFolderDryRunCounts() async throws {
        guard ProcessInfo.processInfo.environment["PARROT_SW_DRYRUN"] == "1" else {
            throw XCTSkip("Set PARROT_SW_DRYRUN=1 to dry-run the real Superwhisper folder")
        }

        let source = SuperwhisperImporter.defaultSourceFolder()
        let importer = SuperwhisperImporter(sourceFolder: source, resolveAppName: nil)
        let options = SuperwhisperImporter.Options(modes: true, vocabulary: true, recordings: true, shortcuts: true, dryRun: true)

        let started = Date()
        let scan = await Task.detached { importer.scan(options: options) }.value
        let report = await importer.apply(scan, options: options, to: SuperwhisperImporter.Targets())

        print("PARROT_SW_DRYRUN begin")
        print("source folder is ~/\(source.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: ""))")
        for line in report.lines { print("PARROT_SW_DRYRUN " + line) }
        print("PARROT_SW_DRYRUN seconds: \(Int(Date().timeIntervalSince(started)))")
        print("PARROT_SW_DRYRUN end")

        XCTAssertTrue(report.dryRun)
        XCTAssertTrue(report.folderExists)
    }
}
