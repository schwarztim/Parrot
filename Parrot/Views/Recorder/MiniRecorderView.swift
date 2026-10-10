import SwiftUI

/// The interim Mini recorder: a pill with the level bars, timer, cancel and
/// an expand button, plus a compact card above it for the mode list,
/// discard guard, result and errors. UI.2 replaces it with the snapping
/// mini recorder and its attached panel.
struct MiniRecorderView: View {
    let model: RecorderPanelModel

    private var state: RecorderViewState { model.state }
    private let cardWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 8) {
            if let hud = state.hudModeName {
                ModeChangedHUDView(modeName: hud)
            }
            if hasCard {
                card
            }
            pill
        }
        .animation(.easeInOut(duration: 0.2), value: state.screen)
    }

    private var hasCard: Bool {
        [.modeSwitch, .cancelGuard, .result, .error].contains(state.screen)
    }

    // MARK: Pill

    private var pill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.screen == .processing ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())

            if state.screen == .processing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 80, height: 22)
            } else {
                LevelBarsView(levels: state.levels, barCount: 14, barWidth: 3, spacing: 2, height: 22)
                    .frame(width: 80)
            }

            if state.showsTimer {
                RecordingTimerText(start: state.startedAt)
            }

            if state.showsCancel {
                Button(action: model.actions.requestCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard recording")
            }

            Button(action: model.actions.expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Expand window")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.screen {
            case .modeSwitch:
                ModeSwitcherView(
                    modes: model.modes,
                    selectedID: model.selectedModeID,
                    onSelect: model.actions.selectMode
                )
            case .cancelGuard:
                CancelGuardView(onDiscard: model.actions.discard, onResume: model.actions.resume)
            case .result:
                ResultPreview(text: state.resultText ?? "", width: cardWidth - 24, onCopy: model.actions.copyResult)
            default:
                EmptyView()
            }
            if let banner = state.banner {
                RecorderBannerView(
                    banner: banner,
                    onSwitchMic: state.screen == .error ? model.actions.switchMic : nil
                )
            }
            if state.primaryButton == .close {
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
