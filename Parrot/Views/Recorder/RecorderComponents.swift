import SwiftUI

// MARK: - Level Bars

/// A row of rounded bars driven by the mic level. With no levels yet the
/// bars idle in a gentle sine motion.
struct LevelBarsView: View {
    let levels: [Float]
    var barCount = 36
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var height: CGFloat = 44
    var color: Color = .red

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let heights = RecorderViewModel.barHeights(
                levels: levels,
                count: barCount,
                time: context.date.timeIntervalSinceReferenceDate
            )
            HStack(alignment: .center, spacing: spacing) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(levels.isEmpty ? 0.45 : 0.9))
                        .frame(width: barWidth, height: max(barWidth, height * heights[index]))
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.08), value: heights)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Timer

/// Elapsed time since `start`, ticking once a second.
struct RecordingTimerText: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: start ?? Date(), by: 1)) { context in
            Text(RecorderViewModel.elapsedText(since: start, now: context.date))
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Keycap

/// A small rounded key, as drawn in the bottom bar and the mode list.
struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

/// A plain bottom-bar button with press feedback (scale and blur).
struct RecorderBarButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (prominent ? 0.1 : 0.05)))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .blur(radius: configuration.isPressed ? 0.4 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Measured Scrolling Text

private struct MeasuredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Text that grows with its content up to `maxHeight`, then scrolls pinned
/// to the bottom with a soft fade at the top edge.
struct GrowingTextArea<Content: View>: View {
    let width: CGFloat
    var minHeight: CGFloat = 20
    var maxHeight: CGFloat = 120
    /// Changes whenever the content does, to keep the bottom in view.
    let scrollKey: String
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let height = min(max(contentHeight, minHeight), maxHeight)
        let overflows = contentHeight > maxHeight
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: MeasuredHeightKey.self, value: geometry.size.height)
                        }
                    )
                    .id("content")
            }
            .frame(width: width, height: height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: overflows ? .clear : .black, location: 0),
                        .init(color: .black, location: overflows ? 0.18 : 0),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onPreferenceChange(MeasuredHeightKey.self) { contentHeight = $0 }
            .onChange(of: scrollKey) {
                proxy.scrollTo("content", anchor: .bottom)
            }
            .onChange(of: contentHeight) {
                proxy.scrollTo("content", anchor: .bottom)
            }
        }
    }
}

// MARK: - Live Text

/// Live transcription: confirmed text in full color, the hypothesis
/// dimmed, a blinking cursor while listening and a shimmer while
/// finalizing.
struct LiveTextView: View {
    let confirmed: String
    let hypothesis: String
    let isFinalizing: Bool
    let width: CGFloat

    @State private var shimmer = false

    var body: some View {
        GrowingTextArea(width: width, scrollKey: confirmed + hypothesis) {
            (Text(confirmed).foregroundColor(.primary)
                + Text(hypothesis).foregroundColor(.secondary)
                + Text(isFinalizing ? "" : " \u{258F}").foregroundColor(.red))
                .font(.body)
                .opacity(isFinalizing && shimmer ? 0.55 : 1)
        }
        .onAppear { startShimmerIfNeeded() }
        .onChange(of: isFinalizing) { startShimmerIfNeeded() }
    }

    private func startShimmerIfNeeded() {
        guard isFinalizing else {
            shimmer = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            shimmer = true
        }
    }
}

// MARK: - Banner

/// The warning strip: no audio, silent mic, lid closed or an error.
struct RecorderBannerView: View {
    let banner: RecorderBanner
    /// Shown for silent-mic banners when set.
    var onSwitchMic: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(banner.title)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if banner.offersSwitchMic, let onSwitchMic {
                Button("Switch Mic", action: onSwitchMic)
                    .buttonStyle(RecorderBarButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.12))
        )
    }
}

// MARK: - Mode Changed Note

/// The brief "mode changed" note.
struct ModeChangedHUDView: View {
    let modeName: String

    var body: some View {
        Label("\(modeName) mode", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Pulse

/// A slow opacity pulse, used for the recording dot. Steady when inactive.
struct PulseModifier: ViewModifier {
    var active = true
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(active && isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}
