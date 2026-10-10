import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Panel

/// Home's stats panel (ui 5.4): a range picker and tiles for speed, words,
/// dictations, apps used, most used mode and time saved. Reads
/// `services.stats`; with no stats yet every tile shows zero. [UI]
struct StatsPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings

    @State private var range: StatsRange = .week
    @State private var snapshot = StatsSnapshot.zero
    @State private var showsTypingTest = false
    @State private var showsShareCard = false

    private var typingWPM: Double { appSettings.general.typingWPM }

    private var saved: TimeInterval {
        StatsMath.timeSaved(words: snapshot.wordCount, speakingSeconds: snapshot.duration, typingWPM: typingWPM)
    }

    /// Reloads after each dictation, a range change or a new stats service.
    private var refreshKey: String {
        "\(range.rawValue)-\(appSettings.general.successfulDictationCount)-\(ObjectIdentifier(appState.services.stats).hashValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your stats")
                    .font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Button {
                    showsShareCard = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Share your stats")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(
                    value: String(format: "%.0f", StatsMath.displayWPM(snapshot)),
                    label: "Average speed",
                    detail: "Words per minute while dictating"
                )
                StatTile(
                    value: StatsMath.countText(snapshot.wordCount),
                    label: "Words",
                    detail: range == .week ? "Words dictated this week" : "Words dictated since you started"
                )
                StatTile(
                    value: StatsMath.countText(snapshot.dictationCount),
                    label: "Dictations",
                    detail: range == .week ? "Recordings this week" : "Recordings since you started"
                )
                StatTile(
                    value: StatsMath.countText(snapshot.appsUsed),
                    label: "Apps used",
                    detail: range == .week ? "Apps you dictated into this week" : "Apps you dictated into since you started"
                )
                StatTile(
                    value: StatsMath.modeText(snapshot.mostUsedMode),
                    label: "Most used mode",
                    detail: range == .week ? "The mode you dictated with most this week" : "The mode you dictated with most since you started"
                )
                StatTile(
                    value: StatsMath.durationText(saved),
                    label: range.savedLabel,
                    detail: "Compared with typing the same words at \(Int(typingWPM.rounded())) WPM"
                ) {
                    Button {
                        showsTypingTest = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Measure your typing speed")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
        .task(id: refreshKey) {
            snapshot = appState.services.stats.snapshot(since: StatsMath.rangeStart(range, now: Date()))
        }
        .sheet(isPresented: $showsTypingTest) {
            TypingTestView()
                .environment(appSettings)
        }
        .sheet(isPresented: $showsShareCard) {
            StatsShareSheet(snapshot: snapshot, range: range, typingWPM: typingWPM)
        }
    }
}

/// One stats tile with an optional accessory button.
private struct StatTile<Accessory: View>: View {
    let value: String
    let label: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            accessory()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.windowBackgroundColor)))
        .hoverTooltip(label, subtitle: detail)
    }
}

private extension StatTile where Accessory == EmptyView {
    init(value: String, label: String, detail: String) {
        self.init(value: value, label: label, detail: detail, accessory: { EmptyView() })
    }
}

// MARK: - Share Card

/// The shareable stats card in Parrot's own look: a green gradient, a
/// waveform fingerprint drawn from the numbers, and the headline figures.
struct StatsShareCard: View {
    let snapshot: StatsSnapshot
    let range: StatsRange
    let typingWPM: Double

    static let size = CGSize(width: 600, height: 340)

    private var wpm: Double { StatsMath.displayWPM(snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "bird.fill")
                Text("Parrot")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Text(range.label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .opacity(0.8)
            }

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(StatsMath.fingerprint(seed: snapshot.wordCount &* 31 &+ Int(wpm), count: 48).enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 6, height: 70 * height)
                }
            }
            .frame(height: 70)

            HStack(spacing: 28) {
                figure(String(format: "%.0f", wpm), "words per minute")
                figure(StatsMath.countText(snapshot.wordCount), "words")
                figure(
                    StatsMath.durationText(StatsMath.timeSaved(words: snapshot.wordCount, speakingSeconds: snapshot.duration, typingWPM: typingWPM)),
                    "saved"
                )
            }

            Text("\(StatsMath.percentFaster(speakingWPM: wpm, typingWPM: StatsMath.averageTypingWPM))% faster than the average typer")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.62, blue: 0.42), Color(red: 0.05, green: 0.42, blue: 0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .opacity(0.8)
        }
    }

    /// The card as PNG data at 2x, or nil if rendering failed.
    @MainActor
    static func pngData(snapshot: StatsSnapshot, range: StatsRange, typingWPM: Double) -> Data? {
        let renderer = ImageRenderer(content: StatsShareCard(snapshot: snapshot, range: range, typingWPM: typingWPM))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The share sheet: the card, Save as PNG and Copy Image.
private struct StatsShareSheet: View {
    let snapshot: StatsSnapshot
    let range: StatsRange
    let typingWPM: Double

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Share your stats")
                .font(.title2.weight(.semibold))
            StatsShareCard(snapshot: snapshot, range: range, typingWPM: typingWPM)
            HStack {
                Button("Copy Image") { copyImage() }
                Button("Save as PNG...") { save() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var png: Data? {
        StatsShareCard.pngData(snapshot: snapshot, range: range, typingWPM: typingWPM)
    }

    private func copyImage() {
        guard let png else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "parrot-stats.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            ErrorToastPanel.show("Could not save the stats card: \(error.localizedDescription)")
        }
    }
}
