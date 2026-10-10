import SwiftUI

// MARK: - Root

private struct RecorderSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The Classic panel's content, or just the mode-changed note. Reports its
/// size so the panel can fit it. (The Mini style has its own windows, see
/// MiniRecorderController.)
struct RecorderRootView: View {
    let model: RecorderPanelModel

    var body: some View {
        content
            // Room for the content's own shadow inside the panel.
            .padding(12)
            .fixedSize()
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: RecorderSizeKey.self, value: geometry.size)
                }
            )
            .onPreferenceChange(RecorderSizeKey.self) { size in
                model.onSizeChange(size)
            }
    }

    @ViewBuilder
    private var content: some View {
        let state = model.state
        if state.screen == .modeChanged, let name = state.hudModeName {
            ModeChangedHUDView(modeName: name)
        } else {
            ClassicRecorderView(model: model)
        }
    }
}

// MARK: - Classic

/// The Classic recorder window: header, level bars or live text, context
/// chips, result preview, banner and the bottom bar.
struct ClassicRecorderView: View {
    let model: RecorderPanelModel

    private var state: RecorderViewState { model.state }
    private let width = RecorderViewModel.classicWidth
    private let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let hud = state.hudModeName {
                ModeChangedHUDView(modeName: hud)
                    .frame(maxWidth: .infinity)
            }

            main

            if !state.chips.isEmpty {
                RecorderChipsView(chips: state.chips)
            }

            if let banner = state.banner {
                RecorderBannerView(
                    banner: banner,
                    onSwitchMic: model.actions.switchMic
                )
            }

            if model.micPickerShown, let devices = model.devices {
                DevicePickerView(devices: devices, onPick: model.actions.pickedMic)
                    .frame(width: width - inset * 2)
            }

            Divider()

            RecorderBottomBar(model: model)
        }
        .padding(inset)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: state.screen)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier(active: [.ready, .wave, .liveText, .cancelGuard, .processing].contains(state.screen)))

            VStack(alignment: .leading, spacing: 1) {
                Text(state.modeName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let destination = state.destinationLabel {
                    Label(destination, systemImage: "scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if state.showsTimer {
                RecordingTimerText(start: state.startedAt)
            }

            Button(action: model.actions.minimize) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Minimize to the mini recorder")
        }
    }

    private var dotColor: Color {
        switch state.screen {
        case .ready, .wave, .liveText, .cancelGuard: return .red
        case .processing: return .orange
        case .error: return .yellow
        default: return .green
        }
    }

    // MARK: Main Content

    @ViewBuilder
    private var main: some View {
        let contentWidth = width - inset * 2
        switch state.screen {
        case .ready, .wave:
            LevelBarsView(levels: state.screen == .ready ? [] : state.levels)
                .frame(width: contentWidth)
        case .liveText:
            VStack(alignment: .leading, spacing: 8) {
                LevelBarsView(levels: state.levels, barCount: 24, barWidth: 3, spacing: 2, height: 18)
                LiveTextView(
                    confirmed: state.confirmedText,
                    hypothesis: state.hypothesisText,
                    isFinalizing: false,
                    width: contentWidth
                )
            }
        case .processing:
            if state.isFinalizing {
                LiveTextView(
                    confirmed: state.confirmedText,
                    hypothesis: state.hypothesisText,
                    isFinalizing: true,
                    width: contentWidth
                )
            } else {
                ProcessingIndicator(progress: state.progress)
                    .frame(width: contentWidth)
            }
        case .result:
            ResultPreview(text: state.resultText ?? "", width: contentWidth, onCopy: model.actions.copyResult)
        case .modeSwitch:
            ModeSwitcherView(
                modes: model.modes,
                selectedID: model.selectedModeID,
                onSelect: model.actions.selectMode
            )
            .frame(width: contentWidth)
        case .cancelGuard:
            CancelGuardView(onDiscard: model.actions.discard, onResume: model.actions.resume)
                .frame(width: contentWidth)
        case .error, .hidden, .modeChanged, .idle:
            EmptyView()
        }
    }
}

// MARK: - Chips

/// "Selected text included in context" and "Clipboard text found".
struct RecorderChipsView: View {
    let chips: [RecorderChip]
    @State private var hovered: RecorderChip.Kind?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Label(chip.title, systemImage: chip.systemImage)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(hovered == chip.kind ? 0.25 : 0.12))
                    )
                    .help(chip.detail)
                    .onHover { inside in
                        hovered = inside ? chip.kind : (hovered == chip.kind ? nil : hovered)
                    }
            }
        }
    }
}

// MARK: - Processing

struct ProcessingIndicator: View {
    let progress: Double?

    var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Processing...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 28)
    }
}

// MARK: - Result

/// The final text, selectable, with a copy button.
struct ResultPreview: View {
    let text: String
    let width: CGFloat
    let onCopy: () -> Void

    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GrowingTextArea(width: width, maxHeight: 200, scrollKey: text) {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            HStack {
                Text("Not pasted. The text is on the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(RecorderBarButtonStyle())
            }
        }
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.easeIn(duration: 0.25)) { shown = true }
        }
    }
}

// MARK: - Discard Guard

/// "Discard recording?" with Discard and Resume.
struct CancelGuardView: View {
    let onDiscard: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Discard recording?", systemImage: "trash")
                .font(.headline)
            Text("The recording is still running. Discard it, or resume and keep talking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(action: onResume) {
                    Text("Resume")
                }
                .buttonStyle(RecorderBarButtonStyle())
                Button(action: onDiscard) {
                    HStack(spacing: 6) {
                        Text("Discard")
                            .foregroundStyle(.red)
                        Keycap(label: "esc")
                    }
                }
                .buttonStyle(RecorderBarButtonStyle(prominent: true))
            }
        }
    }
}

// MARK: - Bottom Bar

/// Mode button, then Cancel (Esc) and Stop or Close.
struct RecorderBottomBar: View {
    let model: RecorderPanelModel

    var body: some View {
        let state = model.state
        HStack(spacing: 8) {
            Button(action: model.actions.openModeSwitcher) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                    Text(state.modeName)
                        .lineLimit(1)
                }
            }
            .buttonStyle(RecorderBarButtonStyle())
            .help("Switch mode")
            .disabled(state.screen == .modeSwitch)

            if model.devices != nil {
                Button(action: model.actions.toggleMicPicker) {
                    Image(systemName: model.micPickerShown ? "mic.fill" : "mic")
                }
                .buttonStyle(RecorderBarButtonStyle())
                .help("Choose microphone")
            }

            Spacer(minLength: 8)

            if state.showsCancel {
                Button(action: model.actions.requestCancel) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        Keycap(label: model.shortcuts.cancel.lowercased() == "esc" ? "esc" : model.shortcuts.cancel)
                    }
                }
                .buttonStyle(RecorderBarButtonStyle())
            }

            switch state.primaryButton {
            case .stop:
                Button(action: model.actions.stop) {
                    HStack(spacing: 6) {
                        Text("Stop")
                        if let key = model.shortcuts.dictation {
                            Keycap(label: key)
                        }
                    }
                }
                .buttonStyle(RecorderBarButtonStyle(prominent: true))
            case .close:
                Button(action: model.actions.close) {
                    HStack(spacing: 6) {
                        Text("Close")
                        Keycap(label: "esc")
                    }
                }
                .buttonStyle(RecorderBarButtonStyle(prominent: true))
            case .none:
                EmptyView()
            }
        }
    }
}
