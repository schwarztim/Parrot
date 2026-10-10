import SwiftUI

/// The mode list shown when `LiveRecordingState.modeSwitcherShown` is set.
///
/// TRG owns the keys (arrows, Return, digits, Esc) and writes the state;
/// this view renders the list with the selected mode highlighted and
/// handles mouse clicks. [UI]
struct ModeSwitcherView: View {
    let modes: [Mode]
    let selectedID: UUID?
    let onSelect: (Mode) -> Void

    @State private var hoveredID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Switch Mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                row(mode, index: index)
            }

            if modes.isEmpty {
                Text("No modes yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func row(_ mode: Mode, index: Int) -> some View {
        let isSelected = mode.id == selectedID
        let isHovered = mode.id == hoveredID
        return Button {
            onSelect(mode)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: mode))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(mode.name)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                if let digit = RecorderViewModel.digitHint(forIndex: index) {
                    Keycap(label: digit)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : Color.primary.opacity(isHovered ? 0.08 : 0)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredID = inside ? mode.id : (hoveredID == mode.id ? nil : hoveredID)
        }
    }

    /// The mode's own symbol, or one for its type.
    static func symbol(for mode: Mode) -> String {
        if !mode.iconName.isEmpty, NSImage(systemSymbolName: mode.iconName, accessibilityDescription: nil) != nil {
            return mode.iconName
        }
        switch mode.type {
        case .super: return "sparkles"
        case .voice: return "waveform"
        case .message: return "message"
        case .email: return "envelope"
        case .note: return "note.text"
        case .meeting: return "person.2"
        case .custom: return "slider.horizontal.3"
        }
    }
}
