import AppKit
import SwiftUI

/// Import from Superwhisper with a dry run and a report. [DATA]
///
/// Reads Superwhisper's folder and never changes it. Shortcuts are opt-in
/// because Superwhisper may still be running with the same keys.
struct ImportView: View {
    static let isReady = true

    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    @State private var sourceFolder = SuperwhisperImporter.defaultSourceFolder()
    @State private var options = SuperwhisperImporter.Options()
    @State private var keepForever = true
    @State private var isRunning = false
    @State private var progressText: String?
    @State private var report: SuperwhisperImporter.Report?

    private var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var retentionDays: Int { appSettings.history.historyRetentionDays }

    var body: some View {
        Form {
            Section {
                Text("Bring your modes, vocabulary, replacements and recordings over from Superwhisper. Parrot only reads Superwhisper's folder; it never changes, moves or deletes anything there. Recordings stay where they are and are linked, not copied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Superwhisper folder") {
                HStack {
                    Image(systemName: folderExists ? "folder.fill" : "questionmark.folder")
                        .foregroundStyle(folderExists ? Color.accentColor : Color.secondary)
                    Text(sourceFolder.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose...", action: chooseFolder)
                    Button("Default") { sourceFolder = SuperwhisperImporter.defaultSourceFolder() }
                }
                if !folderExists {
                    Text("No Superwhisper folder here. Choose the folder named superwhisper.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("What to import") {
                Toggle("Modes", isOn: $options.modes)
                Toggle("Vocabulary and replacements", isOn: $options.vocabulary)
                Toggle("Recordings (history, with audio linked in place)", isOn: $options.recordings)
                if options.recordings && retentionDays > 0 {
                    Toggle("Keep history forever", isOn: $keepForever)
                    Text("History is kept for \(RetentionOption.label(forDays: retentionDays).lowercased()). Older imported recordings would be removed from Parrot's history at the next cleanup unless history is kept forever.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Keyboard shortcuts", isOn: $options.shortcuts)
                Text("Off by default. If Superwhisper is still running with the same keys, both apps react. Quit Superwhisper first if you turn this on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button("Dry Run") { start(dryRun: true) }
                    Button("Import") { start(dryRun: false) }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                    if let progressText {
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isRunning || !folderExists || !(options.modes || options.vocabulary || options.recordings || options.shortcuts))
            } footer: {
                Text("A dry run reads everything and reports what would be imported, without changing anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let report {
                Section(report.dryRun ? "Dry run report" : "Import report") {
                    reportView(report)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Report

    @ViewBuilder
    private func reportView(_ report: SuperwhisperImporter.Report) -> some View {
        let verb = report.dryRun ? "to import" : "imported"
        if options.modes || report.modesFound > 0 {
            LabeledContent("Modes", value: "\(report.modesImported) \(verb), \(report.modesAlreadyPresent) already here, of \(report.modesFound)")
            if report.unresolvedActivationApps > 0 {
                LabeledContent("Apps not found", value: "\(report.unresolvedActivationApps) activation apps skipped")
            }
        }
        if report.vocabularyFound + report.replacementsFound > 0 {
            LabeledContent("Words", value: "\(report.wordsImported) \(verb), of \(report.vocabularyFound)")
            LabeledContent("Replacements", value: "\(report.replacementsImported) \(verb), of \(report.replacementsFound)")
            if report.vocabularyDuplicates > 0 {
                LabeledContent("Already in vocabulary", value: "\(report.vocabularyDuplicates)")
            }
        }
        if report.recordingsFound > 0 {
            LabeledContent("Recordings", value: "\(report.recordingsImported) \(verb), \(report.recordingsAlreadyImported) already imported")
            LabeledContent("Found", value: "\(report.recordingsFound) folders, \(report.recordingsImportable) with text, \(report.recordingsWithAudio) with audio")
            let skipped = SuperwhisperImporter.SkipReason.allCases.compactMap { reason -> String? in
                guard let count = report.skipped[reason], count > 0 else { return nil }
                return "\(count) \(reason.rawValue)"
            }
            if !skipped.isEmpty {
                LabeledContent("Skipped", value: skipped.joined(separator: ", "))
            }
            if report.olderThanRetention > 0 && retentionDays > 0 {
                LabeledContent("Older than retention", value: "\(report.olderThanRetention)")
            }
        }
        if options.shortcuts || report.shortcutsFound > 0 {
            LabeledContent("Shortcuts", value: "\(report.shortcutsImported) \(report.dryRun ? "to set" : "set"), of \(report.shortcutsFound)")
        }
        ForEach(report.errors, id: \.self) { error in
            Text(error).foregroundStyle(.red)
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = sourceFolder.deletingLastPathComponent()
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            sourceFolder = url
        }
    }

    private func start(dryRun: Bool) {
        var options = options
        options.dryRun = dryRun
        if !dryRun && options.recordings && keepForever && retentionDays > 0 {
            appSettings.history.historyRetentionDays = 0
        }
        let importer = SuperwhisperImporter(sourceFolder: sourceFolder)
        let targets = SuperwhisperImporter.Targets(
            history: appState.historyStore,
            vocabulary: appState.vocabularyManager,
            modes: appState.modeManager,
            hotkeys: appSettings.hotkeys,
            retentionDays: appSettings.history.historyRetentionDays
        )
        isRunning = true
        report = nil
        progressText = "Reading Superwhisper's folder..."
        Task {
            let scan = await Task.detached(priority: .userInitiated) {
                importer.scan(options: options) { done, total in
                    Task { @MainActor in progressText = "Reading recordings \(done) of \(total)..." }
                }
            }.value
            progressText = dryRun ? "Counting..." : "Importing..."
            let result = await importer.apply(scan, options: options, to: targets)
            report = result
            progressText = nil
            isRunning = false
            if !dryRun {
                diagLog("[Parrot:Import] " + result.lines.joined(separator: "; "))
                if options.vocabulary, appSettings.vocabulary.vocabularyBoostingEnabled {
                    appState.refreshVocabularyBoosting()
                }
            }
        }
    }
}
