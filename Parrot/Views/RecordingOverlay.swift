import SwiftUI
import AppKit

// MARK: - Floating Panel (NSPanel Wrapper)

class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Floating panel configuration
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        // Don't steal focus from active app
        becomesKeyOnlyIfNeeded = true
    }
}

// MARK: - Recording Overlay View

struct RecordingOverlayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.recordingWindowStyle {
        case .classic:
            classicOverlay
        case .mini:
            miniOverlay
        case .none:
            EmptyView()
        }
    }

    // MARK: - Classic Style

    private var classicOverlay: some View {
        VStack(spacing: 16) {
            // Mode Label
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .modifier(PulseModifier())

                    Text(appState.currentMode?.name ?? "Recording")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                }

                // Destination-aware refinement target.
                if let destination = appState.destinationLabel {
                    Label(destination, systemImage: "scope")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Waveform
            waveformView
                .frame(height: 60)

            // Timer
            Text(formattedDuration)
                .font(.system(.title2, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)

            // Cancel Button
            Button(role: .cancel) {
                cancelRecording()
            } label: {
                Text("Cancel")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(24)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    // MARK: - Mini Style

    private var miniOverlay: some View {
        HStack(spacing: 12) {
            // Recording indicator
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())

            // Mini waveform
            miniWaveformView
                .frame(width: 80, height: 24)

            // Timer
            Text(formattedDuration)
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)

            // Cancel
            Button {
                cancelRecording()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    // MARK: - Waveform Visualization

    private var waveformView: some View {
        GeometryReader { geometry in
            let amplitudes = effectiveAmplitudes(count: 40)
            HStack(spacing: 2) {
                ForEach(0..<amplitudes.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(waveformGradient)
                        .frame(
                            width: max(2, (geometry.size.width - CGFloat(amplitudes.count - 1) * 2) / CGFloat(amplitudes.count)),
                            height: max(3, geometry.size.height * CGFloat(amplitudes[index]))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var miniWaveformView: some View {
        GeometryReader { geometry in
            let amplitudes = effectiveAmplitudes(count: 16)
            HStack(spacing: 1.5) {
                ForEach(0..<amplitudes.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.red.opacity(0.8))
                        .frame(
                            width: max(2, (geometry.size.width - CGFloat(amplitudes.count - 1) * 1.5) / CGFloat(amplitudes.count)),
                            height: max(2, geometry.size.height * CGFloat(amplitudes[index]))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var waveformGradient: LinearGradient {
        LinearGradient(
            colors: [Color.red, Color.red.opacity(0.6)],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func effectiveAmplitudes(count: Int) -> [Float] {
        let source = appState.waveformAmplitudes
        if source.isEmpty {
            // Generate idle placeholder amplitudes
            return (0..<count).map { i in
                Float(0.05 + 0.03 * sin(Double(i) * 0.5))
            }
        }
        if source.count == count {
            return source
        }
        // Resample to desired count
        return (0..<count).map { i in
            let sourceIndex = Float(i) / Float(count) * Float(source.count)
            let lower = Int(sourceIndex)
            let upper = min(lower + 1, source.count - 1)
            let fraction = sourceIndex - Float(lower)
            return source[lower] * (1 - fraction) + source[upper] * fraction
        }
    }

    // MARK: - Timer

    private var formattedDuration: String {
        let totalSeconds = Int(appState.recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let tenths = Int((appState.recordingDuration - Double(totalSeconds)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    // MARK: - Actions

    private func cancelRecording() {
        appState.recordingState = .idle
        appState.recordingDuration = 0
        appState.waveformAmplitudes = []
    }
}

// MARK: - Pulse Animation Modifier

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
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

// MARK: - FloatingPanel Hosting

struct FloatingPanelKey: EnvironmentKey {
    static let defaultValue: FloatingPanel? = nil
}

extension EnvironmentValues {
    var floatingPanel: FloatingPanel? {
        get { self[FloatingPanelKey.self] }
        set { self[FloatingPanelKey.self] = newValue }
    }
}

#Preview("Classic") {
    let state = AppState()
    state.recordingState = .recording
    state.recordingDuration = 5.3
    state.waveformAmplitudes = (0..<40).map { _ in Float.random(in: 0.1...0.9) }

    return RecordingOverlayView()
        .environment(state)
        .frame(width: 320, height: 220)
        .background(Color(.windowBackgroundColor))
}

#Preview("Mini") {
    let state = AppState()
    state.recordingState = .recording
    state.recordingWindowStyle = .mini
    state.recordingDuration = 12.7
    state.waveformAmplitudes = (0..<16).map { _ in Float.random(in: 0.1...0.9) }

    return RecordingOverlayView()
        .environment(state)
        .frame(width: 350, height: 80)
        .background(Color(.windowBackgroundColor))
}
