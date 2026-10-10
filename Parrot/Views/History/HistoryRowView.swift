import SwiftUI

/// One recording in the history list: a collapsed preview, time, app and
/// mode, with a checkbox in multi-select. [DATA]
struct HistoryRowView: View {
    let entry: HistoryEntry
    let query: String
    let isMultiSelect: Bool
    let isChecked: Bool
    let onToggleChecked: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMultiSelect {
                Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleChecked() }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 4) {
                HighlightedText(text: HistoryGrouping.displayText(entry), query: query)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(entry.timestamp, format: .dateTime.hour().minute())
                    if entry.duration > 0 {
                        Text("· \(HistoryGrouping.durationText(entry.duration))")
                    }
                    if let app = entry.appName ?? entry.appBundleID {
                        Text("· \(app)").lineLimit(1)
                    }
                    if let mode = entry.modeName, !mode.isEmpty {
                        Text("· \(mode)").lineLimit(1)
                    }
                    if entry.isImported {
                        Image(systemName: "square.and.arrow.down")
                            .help("Imported from Superwhisper")
                    }
                    if entry.fromFile {
                        Image(systemName: "doc")
                            .help("Transcribed from a file")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
