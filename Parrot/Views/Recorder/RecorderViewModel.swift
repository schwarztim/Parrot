import CoreGraphics
import Foundation

// MARK: - Input

/// Everything the recorder window renders, copied out of
/// `LiveRecordingState` (plus a few UI-side values) so the reducer is a pure
/// function that tests drive without the observable class.
struct RecorderInput: Equatable {
    var phase: DictationPhase = .idle
    var modeName: String?
    var destinationLabel: String?
    var startedAt: Date?
    var levels: [Float] = []
    var silentMicDevice: String?
    var lidWarning: String?
    var confirmedText = ""
    var hypothesisText = ""
    var selectionChip: String?
    var clipboardChip: String?
    var resultText: String?
    var errorText: String?
    var modeSwitcherShown = false
    var cancelGuardShown = false
    var processingProgress: Double?

    /// The saved window style.
    var style: RecordingWindowStyle = .classic
    /// The selected mode's name, shown when the session has no mode yet
    /// (and after it ends, while a result lingers).
    var selectedModeName: String?
    /// A mode chosen a moment ago, for the brief mode-changed HUD.
    var modeChangedName: String?
    /// "Always show": the Mini pill stays up while idle.
    var alwaysShowMini = false
}

extension RecorderInput {
    /// A snapshot of `live` plus the UI-side values.
    @MainActor
    init(
        live: LiveRecordingState,
        style: RecordingWindowStyle,
        selectedModeName: String?,
        modeChangedName: String?,
        alwaysShowMini: Bool = false
    ) {
        self.init(
            phase: live.phase,
            modeName: live.modeName,
            destinationLabel: live.destinationLabel,
            startedAt: live.startedAt,
            levels: live.levels,
            silentMicDevice: live.silentMicDevice,
            lidWarning: live.lidWarning,
            confirmedText: live.confirmedText,
            hypothesisText: live.hypothesisText,
            selectionChip: live.selectionChip,
            clipboardChip: live.clipboardChip,
            resultText: live.resultText,
            errorText: live.errorText,
            modeSwitcherShown: live.modeSwitcherShown,
            cancelGuardShown: live.cancelGuardShown,
            processingProgress: live.processingProgress,
            style: style,
            selectedModeName: selectedModeName,
            modeChangedName: modeChangedName,
            alwaysShowMini: alwaysShowMini
        )
    }
}

// MARK: - View State

/// What the recorder window shows as its main content.
enum RecorderScreen: Equatable {
    /// No window.
    case hidden
    /// The mic is opening.
    case ready
    /// Recording, with the level bars.
    case wave
    /// Recording, with live transcription text.
    case liveText
    /// Stages are running.
    case processing
    /// The final text, after processing.
    case result
    /// The dictation failed or heard nothing.
    case error
    /// The mode list.
    case modeSwitch
    /// "Discard recording?" with discard and resume.
    case cancelGuard
    /// A brief "mode changed" note with no recording in progress.
    case modeChanged
    /// The Mini pill kept on screen while idle by "Always show".
    case idle
}

/// The bottom bar's main button.
enum RecorderPrimaryButton: Equatable {
    case none
    case stop
    case close
}

/// A context chip shown under the level bars.
struct RecorderChip: Equatable, Identifiable {
    enum Kind: Equatable {
        case selection
        case clipboard
    }

    let kind: Kind
    /// What the chip found (shown as its tooltip).
    let detail: String

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .selection: return "Selected text included in context"
        case .clipboard: return "Clipboard text found"
        }
    }

    var systemImage: String {
        switch kind {
        case .selection: return "text.cursor"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

/// A warning strip in the recorder.
enum RecorderBanner: Equatable {
    /// The recording had no voice.
    case noAudio
    /// The named input device delivered only silence.
    case silentMic(device: String)
    /// The lid closed and capture moved to another device.
    case lidClosed(String)
    case error(String)

    var title: String {
        switch self {
        case .noAudio: return "No Audio Detected"
        case .silentMic(let device): return "No audio from \(device)"
        case .lidClosed(let message): return message
        case .error(let message): return message
        }
    }

    /// Silent-mic banners offer "Switch Mic".
    var offersSwitchMic: Bool {
        if case .silentMic = self { return true }
        return false
    }
}

/// Everything the recorder views read, produced by `RecorderViewModel.reduce`.
struct RecorderViewState: Equatable {
    var screen: RecorderScreen
    var style: RecordingWindowStyle
    var modeName: String
    var destinationLabel: String?
    var chips: [RecorderChip]
    var confirmedText: String
    var hypothesisText: String
    /// Live text is in and stages are running (the text shimmers).
    var isFinalizing: Bool
    var resultText: String?
    var banner: RecorderBanner?
    var primaryButton: RecorderPrimaryButton
    /// The Esc cancel button shows (it opens the discard guard).
    var showsCancel: Bool
    var showsTimer: Bool
    var startedAt: Date?
    var levels: [Float]
    var progress: Double?
    /// The mode-changed note shown over the content, if any.
    var hudModeName: String?
    /// The dictation phase, for the Mini pill's record button.
    var phase: DictationPhase = .idle

    var isVisible: Bool { screen != .hidden }
}

// MARK: - Session End

/// What the recorder does when a dictation ends.
enum RecorderEnding: Equatable {
    /// Close the window.
    case close
    /// Keep the window open on the result until Close.
    case showResult(String)
    /// Show the error banner; it dismisses itself after a moment.
    case showError(String)
}

// MARK: - Reducer

/// The recorder's pure logic: view state from live state, what happens when
/// a session ends, level bar heights, timer text and placement. [UI]
enum RecorderViewModel {

    /// The error text a dictation that heard nothing leaves in
    /// `LiveRecordingState.errorText`.
    static let noAudioMessage = "No Audio Detected"

    /// Fixed content width of the Classic window, in points.
    static let classicWidth: CGFloat = 429

    /// Seconds an error banner stays before it dismisses itself.
    static let errorDismissDelay: TimeInterval = 4

    /// Seconds the mode-changed note shows.
    static let modeChangedDuration: TimeInterval = 1.2

    // MARK: View State

    /// The view state for `input`.
    ///
    /// Precedence: the mode switcher (any phase, any style); the discard
    /// guard (recording only, so a release that stops the recording wins
    /// over a guard left open); then by phase. When idle, an error or result
    /// keeps the window up after the session ended, and a recent mode change
    /// shows briefly. Style None hides everything except the switcher and
    /// the mode-changed note.
    static func reduce(_ input: RecorderInput) -> RecorderViewState {
        let liveText = input.confirmedText + input.hypothesisText
        let hasLiveText = !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let result = input.resultText.flatMap { $0.isEmpty ? nil : $0 }
        let error = input.errorText.flatMap { $0.isEmpty ? nil : $0 }

        var screen: RecorderScreen
        if input.modeSwitcherShown {
            screen = .modeSwitch
        } else {
            switch input.phase {
            case .starting:
                screen = .ready
            case .recording:
                if input.cancelGuardShown {
                    screen = .cancelGuard
                } else {
                    screen = hasLiveText ? .liveText : .wave
                }
            case .stopping, .processing:
                if error != nil {
                    screen = .error
                } else if result != nil {
                    screen = .result
                } else {
                    screen = .processing
                }
            case .idle:
                if error != nil {
                    screen = .error
                } else if result != nil {
                    screen = .result
                } else if input.modeChangedName != nil {
                    screen = .modeChanged
                } else {
                    screen = .hidden
                }
            }
        }
        if input.style == .none, screen != .modeSwitch, screen != .modeChanged {
            screen = .hidden
        }
        if screen == .hidden, input.style == .mini, input.alwaysShowMini {
            screen = .idle
        }

        return RecorderViewState(
            screen: screen,
            style: input.style,
            modeName: input.modeName ?? input.selectedModeName ?? "Default",
            destinationLabel: input.destinationLabel,
            chips: chips(for: input, screen: screen),
            confirmedText: input.confirmedText,
            hypothesisText: input.hypothesisText,
            isFinalizing: screen == .processing && hasLiveText,
            resultText: result,
            banner: banner(for: input, error: error),
            primaryButton: primaryButton(for: screen),
            showsCancel: [.ready, .wave, .liveText].contains(screen),
            showsTimer: [.wave, .liveText, .cancelGuard].contains(screen),
            startedAt: input.startedAt,
            levels: input.levels,
            progress: screen == .processing ? input.processingProgress : nil,
            hudModeName: screen == .modeSwitch ? nil : input.modeChangedName,
            phase: input.phase
        )
    }

    private static func chips(for input: RecorderInput, screen: RecorderScreen) -> [RecorderChip] {
        guard [.ready, .wave, .liveText, .processing].contains(screen) else { return [] }
        var chips: [RecorderChip] = []
        if let selection = input.selectionChip {
            chips.append(RecorderChip(kind: .selection, detail: selection))
        }
        if let clipboard = input.clipboardChip {
            chips.append(RecorderChip(kind: .clipboard, detail: clipboard))
        }
        return chips
    }

    private static func banner(for input: RecorderInput, error: String?) -> RecorderBanner? {
        if let error {
            if error == noAudioMessage {
                if let device = input.silentMicDevice { return .silentMic(device: device) }
                return .noAudio
            }
            return .error(error)
        }
        if input.phase == .starting || input.phase == .recording, let device = input.silentMicDevice {
            return .silentMic(device: device)
        }
        if input.phase != .idle, let lid = input.lidWarning {
            return .lidClosed(lid)
        }
        return nil
    }

    private static func primaryButton(for screen: RecorderScreen) -> RecorderPrimaryButton {
        switch screen {
        case .ready, .wave, .liveText: return .stop
        case .result, .error, .modeSwitch: return .close
        case .hidden, .processing, .cancelGuard, .modeChanged, .idle: return .none
        }
    }

    // MARK: Session End

    /// What the window does when a live session ends.
    ///
    /// A confirmed paste closes it. Text that could only be copied stays on
    /// screen unless "Always close" (`closeAfterResult`) is on. Nothing heard
    /// or a failure shows the error banner. Cancelled, discarded (too short)
    /// and agent-routed sessions close.
    static func ending(
        outcome: DictationOutcome?,
        isCancelled: Bool,
        text: String,
        closeAfterResult: Bool
    ) -> RecorderEnding {
        if isCancelled { return .close }
        switch outcome {
        case .pasted:
            return .close
        case .copiedOnly:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if closeAfterResult || trimmed.isEmpty { return .close }
            return .showResult(text)
        case .empty:
            return .showError(noAudioMessage)
        case .failed(let message):
            return .showError(message.isEmpty ? "Dictation failed" : message)
        case .discarded, .routedToAgent, nil:
            return .close
        }
    }

    // MARK: Level Bars

    /// Bar heights (0...1) for `count` bars.
    ///
    /// With no levels yet the bars idle in a gentle sine wave driven by
    /// `time` (seconds). Otherwise the newest `count` levels fill the bars
    /// right to left, padded with the floor on the left, clamped to 0...1
    /// and never below the floor so a quiet bar stays visible.
    static func barHeights(levels: [Float], count: Int, time: TimeInterval) -> [Double] {
        guard count > 0 else { return [] }
        if levels.isEmpty {
            return (0..<count).map { index in
                0.12 + 0.08 * sin(time * 2.4 + Double(index) * 0.55)
            }
        }
        let floor = 0.06
        let recent = levels.suffix(count).map { level -> Double in
            let value = level.isFinite ? Double(level) : 0
            return max(floor, min(1, value))
        }
        return Array(repeating: floor, count: count - recent.count) + recent
    }

    // MARK: Timer

    /// Elapsed recording time as "m:ss", or "0:00" before the start time.
    static func elapsedText(since start: Date?, now: Date) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Mode Switcher

    /// The digit key that picks the mode at `index`: 1 to 9, then 0 for the
    /// tenth, none after that.
    static func digitHint(forIndex index: Int) -> String? {
        switch index {
        case 0..<9: return String(index + 1)
        case 9: return "0"
        default: return nil
        }
    }

    // MARK: Placement

    /// Where the window's bottom-left corner goes.
    ///
    /// A saved origin is used when the window would sit mostly on one of
    /// `screens` (visible frames), nudged fully inside that screen. Without
    /// one, or when that screen is gone, the window goes bottom center of
    /// `fallback`, 60 points above its bottom edge.
    static func origin(
        saved: CGPoint?,
        size: CGSize,
        screens: [CGRect],
        fallback: CGRect
    ) -> CGPoint {
        if let saved {
            let center = CGPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2)
            if let screen = screens.first(where: { $0.contains(center) }) {
                return clamp(origin: saved, size: size, into: screen)
            }
        }
        let origin = CGPoint(x: fallback.midX - size.width / 2, y: fallback.minY + 60)
        return clamp(origin: origin, size: size, into: fallback)
    }

    /// `origin` moved so a window of `size` lies inside `screen` where it
    /// fits (left and bottom edges win when it does not).
    static func clamp(origin: CGPoint, size: CGSize, into screen: CGRect) -> CGPoint {
        let x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        let y = max(screen.minY, min(origin.y, screen.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}
