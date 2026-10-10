import AppKit
import SwiftUI

/// The selected recording: Voice, Speakers and AI tabs, playback, copy,
/// delete, reprocess with another mode, and an info panel. [DATA]
struct HistoryDetailView: View {
    let entry: HistoryEntry
    let query: String
    let playback: AudioPlaybackService
    let modes: [Mode]
    let onCopy: (String) -> Void
    let onDelete: () -> Void
    let onReprocess: (Mode) async -> String

    enum DisplayMode: String, CaseIterable, Identifiable {
        case voice = "Voice"
        case speakers = "Speakers"
        case ai = "AI"
        var id: String { rawValue }
    }

    @State private var display: DisplayMode = .voice
    @State private var details: RecordingDetails?
    @State private var showInfo = false
    @State private var showFullPrompt = false
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var reprocessMessage: String?
    @State private var reprocessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("", selection: $display) {
                            ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)

                        content
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showInfo {
                    Divider()
                    infoPanel
                        .frame(width: 250)
                }
            }
            Divider()
            AudioScrubber(entry: entry, playback: playback)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .onAppear(perform: load)
        .onChange(of: entry.id) { _, _ in load() }
        .confirmationDialog(
            "Are you sure you want to delete this recording? This action cannot be undone.",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func load() {
        details = RecordingDetails.load(for: entry)
        display = entry.hasLLMText ? .ai : .voice
        reprocessMessage = nil
        copied = false
        showFullPrompt = false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryGrouping.detailDate(entry.timestamp))
                    .font(.headline)
                HStack(spacing: 6) {
                    if let app = entry.appName ?? entry.appBundleID { Text(app) }
                    if let mode = entry.modeName, !mode.isEmpty { Text("· \(mode)") }
                    if entry.duration > 0 { Text("· \(HistoryGrouping.durationText(entry.duration))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                onCopy(shownText)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy to clipboard")

            Menu {
                ForEach(modes) { mode in
                    Button(mode.name) { reprocess(with: mode) }
                }
            } label: {
                Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(modes.isEmpty || reprocessing)
            .help("Run this recording again with another mode. The result is copied to the clipboard.")
            .accessibilityIdentifier("mode-reprocess-picker")

            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Info")

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func reprocess(with mode: Mode) {
        reprocessing = true
        reprocessMessage = "Reprocessing with \(mode.name)..."
        Task {
            let message = await onReprocess(mode)
            reprocessMessage = message
            reprocessing = false
        }
    }

    // MARK: - Content

    private var shownText: String {
        switch display {
        case .voice: return entry.rawTranscript.isEmpty ? HistoryGrouping.displayText(entry) : entry.rawTranscript
        case .speakers: return speakerText.isEmpty ? HistoryGrouping.displayText(entry) : speakerText
        case .ai: return entry.llmText.flatMap { $0.isEmpty ? nil : $0 } ?? HistoryGrouping.displayText(entry)
        }
    }

    private var speakerText: String {
        RecordingDetails.speakerTurns(details?.segments ?? [])
            .map { "\($0.speaker ?? "Speaker"): \($0.text)" }
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var content: some View {
        if let reprocessMessage {
            Text(reprocessMessage)
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
                .textSelection(.enabled)
        }

        switch display {
        case .voice:
            let segments = details?.segments ?? []
            if segments.isEmpty {
                textBlock(entry.rawTranscript, empty: "No voice found in recording.")
            } else {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentRow(segment, showSpeaker: false)
                }
            }
        case .speakers:
            let turns = RecordingDetails.speakerTurns(details?.segments ?? [])
            if (details?.speakers ?? []).isEmpty || turns.isEmpty {
                placeholder("Speaker separation was off for this recording.")
            } else {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    segmentRow(turn, showSpeaker: true)
                }
            }
        case .ai:
            if entry.hasLLMText {
                textBlock(entry.llmText ?? "", empty: "")
                if entry.finalText != entry.llmText, !entry.finalText.isEmpty {
                    Text("Delivered text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    textBlock(entry.finalText, empty: "")
                }
            } else {
                placeholder("No language model ran for this recording.")
                if !entry.finalText.isEmpty, entry.finalText != entry.rawTranscript {
                    textBlock(entry.finalText, empty: "")
                }
            }
        }
    }

    private func textBlock(_ text: String, empty: String) -> some View {
        Group {
            if text.isEmpty {
                placeholder(empty)
            } else {
                HighlightedText(text: text, query: query)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment, showSpeaker: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                guard let path = entry.audioPath else { return }
                if playback.currentID != entry.id {
                    playback.play(url: URL(fileURLWithPath: path), id: entry.id)
                }
                playback.seek(to: segment.start)
            } label: {
                Text("\(HistoryGrouping.durationText(segment.start))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Play from here")

            VStack(alignment: .leading, spacing: 2) {
                if showSpeaker, let speaker = segment.speaker {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HighlightedText(text: segment.text, query: query)
                    .textSelection(.enabled)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Info Panel

    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Mode", entry.modeName)
                infoRow("Voice model", entry.voiceModel)
                infoRow("Language model", entry.languageModel)
                infoRow("Language", entry.language)
                infoRow("App", entry.appName ?? entry.appBundleID)
                infoRow("Microphone", entry.device ?? details?.device)
                infoRow("Duration", entry.duration > 0 ? HistoryGrouping.durationText(entry.duration) : nil)
                infoRow("Voice processing", entry.processingTime > 0 ? HistoryGrouping.secondsText(entry.processingTime) : nil)
                infoRow("AI processing", entry.llmProcessingTime > 0 ? HistoryGrouping.secondsText(entry.llmProcessingTime) : nil)
                infoRow("Words", "\(entry.statsWordCount)")
                infoRow("Source", entry.isImported ? "Imported from Superwhisper" : (entry.fromFile ? "File transcription" : "Parrot"))
                if let flags = details?.flags {
                    infoRow("Options", Self.flagSummary(flags))
                }

                if let prompt = details?.renderedPrompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(prompt)
                            .font(.caption)
                            .lineLimit(showFullPrompt ? nil : 4)
                            .textSelection(.enabled)
                        Button(showFullPrompt ? "Show less" : "Show full prompt") { showFullPrompt.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }

                if let folder = entry.folderPath {
                    Button("Reveal in Finder") {
                        let url = URL(fileURLWithPath: folder, isDirectory: true)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.caption).textSelection(.enabled)
            }
        }
    }

    static func flagSummary(_ flags: RecordingMeta.Flags) -> String? {
        var parts: [String] = []
        if flags.translate { parts.append("Translate") }
        if flags.literalPunctuation { parts.append("Literal punctuation") }
        if flags.realtime { parts.append("Realtime") }
        if flags.diarize { parts.append("Speakers") }
        if flags.systemAudio { parts.append("System audio") }
        if flags.applicationContext { parts.append("App context") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
