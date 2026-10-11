import CoreFoundation
import Foundation

/// Imports modes, vocabulary, replacements, recordings and (opt-in)
/// shortcuts from Superwhisper's app folder. [DATA]
///
/// Strictly read-only: files there are only opened for reading and nothing
/// is ever written, moved or deleted in that folder. Recordings are indexed
/// in place (audio referenced by path, never copied) under the source key
/// `superwhisper:<folder name>`, so re-running imports nothing twice. Each
/// recording's `prompt` and `promptContext` are never read (see
/// `Superwhisper.Meta`); only the app name is kept.
///
/// Use: `scan(options:)` off the main thread, then `apply(_:options:to:)`
/// on the main actor. A dry run only counts.
final class SuperwhisperImporter: @unchecked Sendable {

    static let defaultsDomain = "com.superduper.superwhisper"
    static let folderName = "superwhisper"

    struct Options: Equatable, Sendable {
        var modes = true
        var vocabulary = true
        var recordings = true
        /// Off by default: Superwhisper may still be running with the same keys.
        var shortcuts = false
        var dryRun = false
    }

    enum SkipReason: String, CaseIterable, Sendable {
        case emptyFolder = "empty folder"
        case missingMeta = "no meta.json"
        case corruptMeta = "unreadable meta.json"
        case noText = "no text"
    }

    /// Everything read from the folder, before anything is applied.
    struct Scan: Sendable {
        var sourceFolder: URL
        var folderExists = false
        var settings: Superwhisper.SettingsFile?
        var settingsUnreadable = false
        var modes: [Superwhisper.ModeFile] = []
        var unreadableModes = 0
        var recordingsFound = 0
        var records: [HistoryRecord] = []
        var recordingsWithAudio = 0
        var skipped: [SkipReason: Int] = [:]
        /// Decoded shortcuts by Parrot name.
        var shortcuts: [ShortcutName: Shortcut] = [:]
    }

    /// What an import (or dry run) did. Counts only: no transcript, prompt,
    /// vocabulary or replacement text.
    struct Report: Equatable, Sendable {
        var sourceFolder = ""
        var dryRun = false
        var folderExists = false
        var modesFound = 0
        var modesImported = 0
        var modesAlreadyPresent = 0
        var unreadableModes = 0
        var unresolvedActivationApps = 0
        var vocabularyFound = 0
        var replacementsFound = 0
        var wordsImported = 0
        var replacementsImported = 0
        var vocabularyDuplicates = 0
        var recordingsFound = 0
        var recordingsImportable = 0
        var recordingsWithAudio = 0
        var recordingsImported = 0
        var recordingsAlreadyImported = 0
        var skipped: [SkipReason: Int] = [:]
        /// Imported recordings older than the retention setting (they go at
        /// the next cleanup unless retention is Forever).
        var olderThanRetention = 0
        var shortcutsFound = 0
        var shortcutsImported = 0
        var errors: [String] = []

        /// One line per count, safe to print.
        var lines: [String] {
            var lines = [
                "source folder found: \(folderExists)",
                "modes found: \(modesFound), \(dryRun ? "would import" : "imported"): \(modesImported), already present: \(modesAlreadyPresent), unreadable: \(unreadableModes), unresolved activation apps: \(unresolvedActivationApps)",
                "vocabulary words found: \(vocabularyFound), replacements found: \(replacementsFound)",
                "words \(dryRun ? "to import" : "imported"): \(wordsImported), replacements \(dryRun ? "to import" : "imported"): \(replacementsImported), duplicates: \(vocabularyDuplicates)",
                "recordings found: \(recordingsFound), importable: \(recordingsImportable), with audio: \(recordingsWithAudio)",
                "recordings \(dryRun ? "to import" : "imported"): \(recordingsImported), already imported: \(recordingsAlreadyImported)",
            ]
            for reason in SkipReason.allCases {
                lines.append("skipped (\(reason.rawValue)): \(skipped[reason] ?? 0)")
            }
            lines.append("older than retention: \(olderThanRetention)")
            lines.append("shortcuts found: \(shortcutsFound), \(dryRun ? "would set" : "set"): \(shortcutsImported)")
            if !errors.isEmpty { lines.append("errors: \(errors.count)") }
            return lines
        }
    }

    /// Where the import writes. Nil targets are skipped.
    struct Targets {
        var history: HistoryStore?
        var vocabulary: VocabularyManager?
        var modes: ModeManager?
        var hotkeys: HotkeySettings?
        /// Days kept by retention (0 forever), for the report.
        var retentionDays = 0
    }

    let sourceFolder: URL
    private let fileManager: FileManager
    /// App display name to bundle id, for recordings. Nil skips resolution.
    private let resolveAppName: ((String) -> String?)?
    /// Raw Superwhisper defaults (`KeyboardShortcuts_*` keys are read).
    private let shortcutDefaults: () -> [String: Any]

    init(
        sourceFolder: URL,
        fileManager: FileManager = .default,
        resolveAppName: ((String) -> String?)? = AppResolver.bundleID(forAppName:),
        shortcutDefaults: @escaping () -> [String: Any] = SuperwhisperImporter.readShortcutDefaults
    ) {
        self.sourceFolder = sourceFolder
        self.fileManager = fileManager
        self.resolveAppName = resolveAppName
        self.shortcutDefaults = shortcutDefaults
    }

    // MARK: - Source Folder

    /// Superwhisper's app folder: `appFolderDirectory` (the parent folder)
    /// plus `superwhisper` when set, else `~/Documents/superwhisper`.
    static func defaultSourceFolder(appFolderDirectory: String?, home: URL) -> URL {
        guard var value = appFolderDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return home.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
        }
        if value.hasPrefix("file://"), let url = URL(string: value) {
            value = url.path
        }
        if value == "~" {
            value = home.path
        } else if value.hasPrefix("~/") {
            value = home.path + value.dropFirst(1)
        }
        var url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        if url.lastPathComponent.lowercased() != folderName {
            url.appendPathComponent(folderName, isDirectory: true)
        }
        return url
    }

    /// The folder from Superwhisper's preferences (read-only).
    static func defaultSourceFolder() -> URL {
        let value = CFPreferencesCopyAppValue("appFolderDirectory" as CFString, defaultsDomain as CFString) as? String
        return defaultSourceFolder(appFolderDirectory: value, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Every key in Superwhisper's defaults domain, read-only.
    static func readShortcutDefaults() -> [String: Any] {
        let domain = defaultsDomain as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else {
            return [:]
        }
        let wanted = keys.filter { $0.hasPrefix(SuperwhisperShortcut.defaultsKeyPrefix) }
        guard !wanted.isEmpty,
              let values = CFPreferencesCopyMultiple(wanted as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        else { return [:] }
        return values
    }

    // MARK: - Scan (read-only)

    func scan(options: Options, progress: ((Int, Int) -> Void)? = nil) -> Scan {
        var scan = Scan(sourceFolder: sourceFolder)
        var isDirectory: ObjCBool = false
        scan.folderExists = fileManager.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard scan.folderExists else { return scan }

        if options.vocabulary || options.modes {
            let url = sourceFolder.appendingPathComponent("settings/settings.json")
            if fileManager.fileExists(atPath: url.path) {
                if let data = try? Data(contentsOf: url),
                   let settings = try? JSONDecoder().decode(Superwhisper.SettingsFile.self, from: data) {
                    scan.settings = settings
                } else {
                    scan.settingsUnreadable = true
                }
            }
        }
        if options.modes {
            readModes(into: &scan)
        }
        if options.recordings {
            scanRecordings(into: &scan, resolve: options.dryRun ? nil : resolveAppName, progress: progress)
        }
        if options.shortcuts {
            for (key, value) in shortcutDefaults() {
                guard let name = SuperwhisperShortcut.shortcutName(forDefaultsKey: key),
                      let shortcut = SuperwhisperShortcut.shortcut(fromDefaultsValue: value)
                else { continue }
                scan.shortcuts[name] = shortcut
            }
        }
        return scan
    }

    private func readModes(into scan: inout Scan) {
        let folder = sourceFolder.appendingPathComponent("modes", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names.sorted() where name.lowercased().hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  var mode = try? JSONDecoder().decode(Superwhisper.ModeFile.self, from: data)
            else {
                scan.unreadableModes += 1
                continue
            }
            if (mode.key ?? "").isEmpty { mode.key = String(name.dropLast(5)) }
            scan.modes.append(mode)
        }
        // The user's mode order from settings.json.
        if let order = scan.settings?.modeKeys, !order.isEmpty {
            let rank = Dictionary(order.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            scan.modes.sort { (rank[($0.key ?? "").lowercased()] ?? Int.max) < (rank[($1.key ?? "").lowercased()] ?? Int.max) }
        }
    }

    private func scanRecordings(into scan: inout Scan, resolve: ((String) -> String?)?, progress: ((Int, Int) -> Void)?) {
        let root = sourceFolder.appendingPathComponent("recordings", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        let folders = names.filter(RecordingFolders.isRecordingFolderName).sorted()
        var appCache: [String: String?] = [:]

        for (index, name) in folders.enumerated() {
            if index % 250 == 0 { progress?(index, folders.count) }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            scan.recordingsFound += 1

            let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path))?.filter { $0 != ".DS_Store" } ?? []
            guard !contents.isEmpty else {
                scan.skipped[.emptyFolder, default: 0] += 1
                continue
            }
            let metaURL = folder.appendingPathComponent("meta.json")
            guard contents.contains("meta.json") else {
                scan.skipped[.missingMeta, default: 0] += 1
                continue
            }
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(Superwhisper.Meta.self, from: data)
            else {
                scan.skipped[.corruptMeta, default: 0] += 1
                continue
            }
            guard !meta.hasNoText else {
                scan.skipped[.noText, default: 0] += 1
                continue
            }

            var bundleID: String?
            if let resolve, let app = meta.appName, !app.isEmpty {
                if let cached = appCache[app] {
                    bundleID = cached
                } else {
                    bundleID = resolve(app)
                    appCache[app] = bundleID
                }
            }
            guard let record = meta.historyRecord(folder: folder, appBundleID: bundleID) else {
                scan.skipped[.corruptMeta, default: 0] += 1
                continue
            }
            if record.audioPath != nil { scan.recordingsWithAudio += 1 }
            scan.records.append(record)
        }
        progress?(folders.count, folders.count)
    }

    // MARK: - Mapping

    /// A Superwhisper mode in Parrot's schema. Model ids are not carried
    /// over (Superwhisper's ids mean nothing to Parrot), so the mode uses
    /// Parrot's default voice and language models. Returns the activation
    /// apps that could not be resolved to a bundle id.
    static func mode(
        from file: Superwhisper.ModeFile,
        includeShortcut: Bool,
        resolveActivationApp: (String) -> String? = AppResolver.bundleID(forActivationApp:)
    ) -> (mode: Mode, unresolvedApps: [String]) {
        let type = file.type.flatMap { ModeType(rawValue: $0.lowercased()) } ?? .custom
        let prompt = file.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var bundleIDs: [String] = []
        var unresolved: [String] = []
        for app in file.activationApps {
            if let id = resolveActivationApp(app) {
                if !bundleIDs.contains(where: { $0.lowercased() == id.lowercased() }) { bundleIDs.append(id) }
            } else {
                unresolved.append(app)
            }
        }

        var playback = file.playbackBehavior.flatMap { PlaybackBehavior(rawValue: $0) }
        if playback == nil {
            if file.pauseMediaPlayback == true {
                playback = .pause
            } else if file.duckOutputVolume == true || file.adjustOutputVolume == true {
                playback = .duck
            }
        }

        let mode = Mode(
            key: file.key,
            name: (file.name ?? "").isEmpty ? (file.key ?? "Imported mode") : (file.name ?? ""),
            description: file.description ?? "",
            type: type,
            iconName: file.iconName ?? "",
            language: (file.language ?? "").isEmpty ? "auto" : (file.language ?? "auto"),
            translateToEnglish: file.translateToEnglish ?? false,
            literalPunctuation: file.literalPunctuation ?? false,
            realtimeOutput: file.realtimeOutput ?? false,
            diarize: file.diarize ?? false,
            useSystemAudio: file.useSystemAudio ?? false,
            tone: file.tone.flatMap { Tone(rawValue: $0) },
            refinementPrompt: (type == .voice || prompt.isEmpty) ? nil : prompt,
            promptExamples: file.promptExamples
                .filter { !$0.input.isEmpty || !$0.output.isEmpty }
                .map { PromptExample(input: $0.input, output: $0.output) },
            contextTemplate: file.contextTemplate ?? "",
            contextFromSelection: file.contextFromSelection ?? false,
            contextFromClipboard: file.contextFromClipboard ?? false,
            contextFromActiveApplication: file.contextFromActiveApplication ?? false,
            appBundleIDs: bundleIDs.isEmpty ? nil : bundleIDs,
            activationSites: file.activationSites,
            script: file.script ?? "",
            scriptEnabled: file.scriptEnabled ?? false,
            autoPaste: file.autoPaste,
            autocapitalizeInsert: file.autocapitalizeInsert ?? file.smartCapitalization ?? true,
            playbackBehavior: playback,
            shortcut: includeShortcut ? file.shortcut?.modeShortcut : nil
        )
        return (mode, unresolved)
    }

    /// Replacements first, then words, so a word that is also a
    /// replacement's original keeps the replacement.
    static func vocabularyEntries(from settings: Superwhisper.SettingsFile) -> [VocabularyEntry] {
        let replacements = settings.replacements
            .filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { replacement -> VocabularyEntry in
                let text = replacement.with.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? .word(replacement.original) : VocabularyEntry(original: replacement.original, replacement: replacement.with)
            }
        let words = settings.vocabulary
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { VocabularyEntry.word($0) }
        return replacements + words
    }

    // MARK: - Apply

    /// Writes the scan into Parrot (or only counts, for a dry run).
    @MainActor
    func apply(_ scan: Scan, options: Options, to targets: Targets, now: Date = Date()) async -> Report {
        var report = Report()
        report.sourceFolder = scan.sourceFolder.path
        report.dryRun = options.dryRun
        report.folderExists = scan.folderExists
        guard scan.folderExists else {
            report.errors.append("Superwhisper folder not found")
            return report
        }
        if scan.settingsUnreadable { report.errors.append("settings.json could not be read") }

        if options.modes {
            applyModes(scan, options: options, targets: targets, report: &report)
        }
        if options.vocabulary, let settings = scan.settings {
            report.vocabularyFound = settings.vocabulary.count
            report.replacementsFound = settings.replacements.count
            let incoming = Self.vocabularyEntries(from: settings)
            let existing = targets.vocabulary?.entries ?? []
            let result = options.dryRun
                ? VocabularyMerge.merge(existing: existing, incoming: incoming)
                : (targets.vocabulary?.merge(incoming) ?? VocabularyMerge.merge(existing: existing, incoming: incoming))
            report.wordsImported = result.wordsAdded
            report.replacementsImported = result.replacementsAdded + result.upgraded
            report.vocabularyDuplicates = result.duplicates
        }
        if options.recordings {
            await applyRecordings(scan, options: options, targets: targets, now: now, report: &report)
        }
        if options.shortcuts {
            report.shortcutsFound = scan.shortcuts.count
            report.shortcutsImported = scan.shortcuts.count
            if !options.dryRun, let hotkeys = targets.hotkeys {
                for name in ShortcutName.allCases {
                    if let shortcut = scan.shortcuts[name] { hotkeys.setShortcut(shortcut, for: name) }
                }
            }
        }
        return report
    }

    @MainActor
    private func applyModes(_ scan: Scan, options: Options, targets: Targets, report: inout Report) {
        report.modesFound = scan.modes.count
        report.unreadableModes = scan.unreadableModes
        var names = Set((targets.modes?.modes ?? []).map { $0.name.lowercased() })
        for file in scan.modes {
            let mapped = Self.mode(from: file, includeShortcut: options.shortcuts)
            report.unresolvedActivationApps += mapped.unresolvedApps.count
            let name = mapped.mode.name.lowercased()
            guard !names.contains(name) else {
                report.modesAlreadyPresent += 1
                continue
            }
            names.insert(name)
            report.modesImported += 1
            if !options.dryRun {
                targets.modes?.addMode(mapped.mode)
            }
        }
    }

    @MainActor
    private func applyRecordings(_ scan: Scan, options: Options, targets: Targets, now: Date, report: inout Report) async {
        report.recordingsFound = scan.recordingsFound
        report.recordingsImportable = scan.records.count
        report.recordingsWithAudio = scan.recordingsWithAudio
        report.skipped = scan.skipped

        let known = (try? targets.history?.sourceKeys(withPrefix: HistoryEntry.SourceKey.superwhisperPrefix)) ?? []
        let fresh = scan.records.filter { !known.contains($0.sourceKey ?? "") }
        report.recordingsAlreadyImported = scan.records.count - fresh.count

        if targets.retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(targets.retentionDays) * 86_400)
            report.olderThanRetention = scan.records.filter { $0.timestamp < cutoff }.count
        }

        if options.dryRun {
            report.recordingsImported = fresh.count
            return
        }
        guard let history = targets.history else {
            report.errors.append("History is unavailable")
            return
        }
        do {
            report.recordingsImported = try await Task.detached(priority: .userInitiated) {
                try history.importRecords(fresh)
            }.value
        } catch {
            report.errors.append("Recordings could not be saved: \(error.localizedDescription)")
        }
    }
}

// MARK: - App Resolution

/// Resolves Superwhisper's app identifiers to bundle ids. [DATA]
enum AppResolver {

    /// Folders searched for `<name>.app`.
    static var applicationFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// True for strings shaped like `com.example.App`.
    static func looksLikeBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !value.contains(" "), !value.contains("/") else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// An activation app entry: a bundle id, a path or `.app` URL, or a name.
    static func bundleID(forActivationApp value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return Bundle(url: url)?.bundleIdentifier
        }
        if trimmed.hasPrefix("/") || trimmed.lowercased().hasSuffix(".app") && trimmed.contains("/") {
            return Bundle(path: trimmed)?.bundleIdentifier
        }
        if looksLikeBundleID(trimmed) && !trimmed.lowercased().hasSuffix(".app") {
            return trimmed
        }
        return bundleID(forAppName: trimmed)
    }

    /// An app display name to its bundle id, by finding `<name>.app`.
    static func bundleID(forAppName name: String) -> String? {
        let clean = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        guard !clean.isEmpty, !clean.contains("/") else { return nil }
        for folder in applicationFolders {
            let url = folder.appendingPathComponent(clean + ".app", isDirectory: true)
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }
}
