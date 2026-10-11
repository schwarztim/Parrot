import SwiftUI

// MARK: - Size Reporting

private struct MiniSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension View {
    /// Reports the view's size so its panel can fit it.
    func reportsSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: MiniSizeKey.self, value: geometry.size)
            }
        )
        .onPreferenceChange(MiniSizeKey.self, perform: onChange)
    }
}

// MARK: - Pill

/// The Mini recorder pill (ui 2.4): record, level bars, mode and expand.
/// Drag it to another snap point; right click for the context menu.
struct MiniRecorderView: View {
    let model: RecorderPanelModel
    let mini: MiniPanelModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activity: MiniPillActivity { mini.presentation.activity }

    var body: some View {
        HStack(spacing: 4) {
            MiniPillButton(control: .record, mini: mini, help: recordHelp, action: model.actions.toggleRecording) {
                recordIcon
            }
            .disabled(activity == .processing)

            LevelBarsView(
                levels: activity == .recording ? model.state.levels : [],
                barCount: MiniRecorderLogic.barCount(for: activity),
                barWidth: 3,
                spacing: 2,
                height: 16,
                color: activity == .recording ? .red : .secondary
            )
            .frame(width: CGFloat(MiniRecorderLogic.barCount(for: activity)) * 5)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: activity)

            MiniPillButton(control: .mode, mini: mini, help: "Switch mode", action: model.actions.openModeSwitcher) {
                Image(systemName: "square.stack.3d.up")
            }

            MiniPillButton(control: .expand, mini: mini, help: "Expand window", action: model.actions.expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in mini.onDragChanged() }
                .onEnded { _ in mini.onDragEnded() }
        )
        .contextMenu {
            Button("Expand window", action: model.actions.expand)
            Button("Open History...", action: model.actions.openHistory)
            Button("Open Settings...", action: model.actions.openSettings)
        }
        // Room for the shadow inside the panel.
        .padding(8)
        .fixedSize()
        .reportsSize(mini.onPillSize)
    }

    private var recordHelp: String {
        switch activity {
        case .idle: return "Start recording"
        case .recording: return "Stop recording"
        case .processing: return "Working..."
        }
    }

    @ViewBuilder
    private var recordIcon: some View {
        switch activity {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            Image(systemName: "stop.fill")
                .foregroundStyle(.red)
                .modifier(PulseModifier(active: !reduceMotion))
        case .processing:
            ProgressView()
                .controlSize(.mini)
        }
    }
}

/// A round pill button with a hover background, which drags suppress.
private struct MiniPillButton<Label: View>: View {
    let control: MiniControl
    let mini: MiniPanelModel
    let help: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovered && !mini.isDragging ? Color.primary.opacity(0.1) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .onHover { inside in
            isHovered = inside
            mini.onHover(inside ? control : nil)
        }
    }
}

// MARK: - Attached Panel

/// The panel attached above or below the pill: the mode list, discard
/// guard, result, error, the agent slot, or a hover hint.
struct MiniAttachedView: View {
    let model: RecorderPanelModel
    let mini: MiniPanelModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardWidth: CGFloat = 300

    var body: some View {
        Group {
            if let aux = mini.presentation.aux {
                card(aux)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: mini.auxPin == .above ? .bottom : .top)))
            } else if let hint = mini.hint {
                MiniHintStrip(hint: hint, keycaps: keycaps(for: hint))
                    .transition(reduceMotion ? .opacity : .move(edge: mini.auxPin == .above ? .bottom : .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: mini.presentation.aux)
        .padding(8)
        .fixedSize()
        .reportsSize(mini.onAuxSize)
    }

    private func keycaps(for hint: MiniHint) -> [String] {
        switch hint {
        case .start: return model.toggleKeycaps
        case .mode: return model.changeModeKeycaps
        case .cancel: return [model.shortcuts.cancel]
        case .modeSelected, .stop, .expand: return []
        }
    }

    private func card(_ aux: MiniAux) -> some View {
        let state = model.state
        return VStack(alignment: .leading, spacing: 10) {
            switch aux {
            case .modeList:
                ModeSwitcherView(
                    modes: model.modes,
                    selectedID: model.selectedModeID,
                    onSelect: model.actions.selectMode
                )
            case .discard:
                MiniHintStrip(hint: .cancel, keycaps: [model.shortcuts.cancel], framed: false)
                CancelGuardView(onDiscard: model.actions.discard, onResume: model.actions.resume)
            case .result:
                HStack {
                    Text("Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        mini.isAuxPinned.toggle()
                    } label: {
                        Image(systemName: mini.isAuxPinned ? "pin.fill" : "pin")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(mini.isAuxPinned ? "Unpin: close on outside click" : "Pin: keep open on outside click")
                }
                ResultPreview(text: state.resultText ?? "", width: cardWidth - 24, onCopy: model.actions.copyResult)
            case .error:
                if let banner = state.banner {
                    RecorderBannerView(banner: banner, onSwitchMic: model.actions.switchMic)
                }
            case .agent:
                // AGT fills this slot with the reply composer.
                Text("Agent replies appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.micPickerShown, let devices = model.devices {
                DevicePickerView(devices: devices, onPick: model.actions.pickedMic)
            }

            if aux == .result || aux == .error {
                HStack {
                    Spacer()
                    Button(action: model.actions.close) {
                        HStack(spacing: 6) {
                            Text("Close")
                            Keycap(label: "esc")
                        }
                    }
                    .buttonStyle(RecorderBarButtonStyle(prominent: true))
                }
            }
        }
        .padding(12)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// Icon, text and shortcut keycaps in a small strip.
struct MiniHintStrip: View {
    let hint: MiniHint
    let keycaps: [String]
    var framed = true

    var body: some View {
        let strip = HStack(spacing: 8) {
            Image(systemName: hint.systemImage)
                .foregroundStyle(.secondary)
            Text(hint.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Keycap(label: cap)
            }
        }
        if framed {
            strip
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        } else {
            strip
        }
    }
}

// MARK: - Snap Indicator

/// The marker shown at a snap point while the pill is dragged.
struct SnapIndicatorView: View {
    var isNearest: Bool
    var isEngaged: Bool

    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(isEngaged ? 0.9 : (isNearest ? 0.55 : 0.2)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            .frame(width: 40, height: 10)
            .padding(2)
    }
}
