import Foundation

/// Where Parrot keeps its files. Frozen.
///
/// The root is `~/Library/Application Support/Parrot/`; tests pass a
/// temporary root. Accessors only build URLs. Call `ensureDirectory(_:)`
/// before writing into one.
///
/// Layout:
///   recordings/<unix-seconds>/output.wav and meta.json
///   modes/
///   agent/inbox/
///
/// Files that keep their current paths for now (moving one needs a
/// migration): the history database `parrot.db` (HistoryStore), the
/// vocabulary `vocabulary.json` (VocabularyManager), the mode list
/// `modes.json` (ModeManager) and the debug log `diag.log` (AppState). All
/// four sit directly in the root and are listed below so new code can find
/// them without hardcoding names.
struct AppPaths: Sendable, Equatable {

    let root: URL

    init(root: URL = AppPaths.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/Parrot/`. Inside a test run it is a
    /// private temporary folder instead, so no test can ever write into the
    /// user's real recordings, history, modes or vocabulary.
    static var defaultRoot: URL {
        isRunningTests ? testRoot : productionRoot
    }

    /// The real `~/Library/Application Support/Parrot/`, whatever process
    /// asks. Only the app (and the agent hook helper) should open it.
    static var productionRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot", isDirectory: true)
    }

    /// True when XCTest is loaded into this process.
    static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

    /// One throwaway root per test process.
    private static let testRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("parrot-test-root-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    // MARK: - Recordings

    /// Parent of every recording folder.
    var recordings: URL {
        root.appendingPathComponent("recordings", isDirectory: true)
    }

    /// The folder for a recording that started at `startedAt`, named by its
    /// whole unix seconds.
    func recordingFolder(startedAt: Date) -> URL {
        recordings.appendingPathComponent(String(Int(startedAt.timeIntervalSince1970)), isDirectory: true)
    }

    /// The captured audio inside a recording folder.
    func recordingAudio(in folder: URL) -> URL {
        folder.appendingPathComponent("output.wav")
    }

    /// The recording's metadata inside a recording folder.
    func recordingMeta(in folder: URL) -> URL {
        folder.appendingPathComponent("meta.json")
    }

    // MARK: - Modes and Agent

    /// One file per mode.
    var modes: URL {
        root.appendingPathComponent("modes", isDirectory: true)
    }

    /// Requests written by the agent hook helper.
    var agentInbox: URL {
        root.appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    // MARK: - Existing Files (not moved yet)

    var historyDatabase: URL { root.appendingPathComponent("parrot.db") }
    var vocabularyFile: URL { root.appendingPathComponent("vocabulary.json") }
    var legacyModesFile: URL { root.appendingPathComponent("modes.json") }
    var diagnosticLog: URL { root.appendingPathComponent("diag.log") }

    // MARK: - Helpers

    /// Creates `directory` and its parents if needed, then returns it.
    @discardableResult
    func ensureDirectory(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
