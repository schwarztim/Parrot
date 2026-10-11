import Foundation
import Observation

// MARK: - Presentation

/// What the Mini pill's record button shows.
enum MiniPillActivity: Equatable {
    case idle
    case recording
    case processing
}

/// What the attached panel above or below the pill shows.
enum MiniAux: Equatable {
    /// The mode list.
    case modeList
    /// "Discard recording?" with discard and resume.
    case discard
    /// The final text that could not be pasted.
    case result
    /// No audio, silent mic or a failure, with Switch Mic where it applies.
    case error
    /// Reserved for the coding agent's reply composer (AGT, later).
    case agent
}

/// The pill's controls, for hover hints.
enum MiniControl: Equatable {
    case record
    case mode
    case expand
}

/// A hint strip that slides out next to the pill.
enum MiniHint: Equatable {
    case mode(String)
    case modeSelected(String)
    case start
    case stop
    case expand
    case cancel

    var title: String {
        switch self {
        case .mode(let name): return "\(name) mode active"
        case .modeSelected(let name): return "\(name) mode selected"
        case .start: return "Start recording"
        case .stop: return "Stop recording"
        case .expand: return "Expand window"
        case .cancel: return "Discard recording?"
        }
    }

    var systemImage: String {
        switch self {
        case .mode: return "square.stack.3d.up"
        case .modeSelected: return "checkmark.circle.fill"
        case .start: return "mic.fill"
        case .stop: return "stop.fill"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .cancel: return "xmark.circle"
        }
    }
}

/// The Mini recorder's state for one view state. [UI]
struct MiniPresentation: Equatable {
    var showsPill: Bool
    var activity: MiniPillActivity
    var aux: MiniAux?
    /// A hint that shows without hovering (a mode was just chosen).
    var passiveHint: MiniHint?

    static let hidden = MiniPresentation(showsPill: false, activity: .idle, aux: nil, passiveHint: nil)
}

/// Pure Mini recorder logic: presentation and hints. [UI]
enum MiniRecorderLogic {

    /// Seconds the pointer rests on a control before its hint shows.
    static let hintDelay: TimeInterval = 0.35
    /// Seconds a hint stays after the pointer leaves.
    static let hintLinger: TimeInterval = 0.25
    /// Seconds an outside click waits before closing the attached panel, so
    /// a quick click back does not flicker it.
    static let auxCloseDelay: TimeInterval = 0.12
    /// Level bars while idle, and while recording.
    static let idleBarCount = 5
    static let recordingBarCount = 12

    static func presentation(for state: RecorderViewState) -> MiniPresentation {
        let activity: MiniPillActivity
        switch state.phase {
        case .starting, .recording: activity = .recording
        case .stopping, .processing: activity = .processing
        case .idle: activity = .idle
        }
        switch state.screen {
        case .hidden:
            return .hidden
        case .idle, .ready, .wave, .liveText, .processing:
            return MiniPresentation(showsPill: true, activity: activity, aux: nil, passiveHint: nil)
        case .cancelGuard:
            return MiniPresentation(showsPill: true, activity: activity, aux: .discard, passiveHint: nil)
        case .modeSwitch:
            return MiniPresentation(showsPill: true, activity: activity, aux: .modeList, passiveHint: nil)
        case .result:
            return MiniPresentation(showsPill: true, activity: activity, aux: .result, passiveHint: nil)
        case .error:
            return MiniPresentation(showsPill: true, activity: activity, aux: .error, passiveHint: nil)
        case .modeChanged:
            let hint = state.hudModeName.map(MiniHint.modeSelected)
            return MiniPresentation(showsPill: true, activity: activity, aux: nil, passiveHint: hint)
        }
    }

    /// The hint for the hovered control.
    static func hint(for control: MiniControl, activity: MiniPillActivity, modeName: String) -> MiniHint? {
        switch control {
        case .record:
            switch activity {
            case .idle: return .start
            case .recording: return .stop
            case .processing: return nil
            }
        case .mode:
            return .mode(modeName)
        case .expand:
            return .expand
        }
    }

    /// Bars to draw for `activity`.
    static func barCount(for activity: MiniPillActivity) -> Int {
        activity == .recording ? recordingBarCount : idleBarCount
    }
}

// MARK: - Panel Model

/// The values the Mini views read and the callbacks they make.
/// MiniRecorderController writes it.
@MainActor
@Observable
final class MiniPanelModel {
    var presentation = MiniPresentation.hidden
    /// The hint showing now (hovered or passive).
    var hint: MiniHint?
    var isDragging = false
    /// A pinned panel ignores outside clicks.
    var isAuxPinned = false
    var auxPin: AuxPin = .above
    var reduceMotion = false

    @ObservationIgnored var onHover: (MiniControl?) -> Void = { _ in }
    @ObservationIgnored var onDragChanged: () -> Void = {}
    @ObservationIgnored var onDragEnded: () -> Void = {}
    @ObservationIgnored var onPillSize: (CGSize) -> Void = { _ in }
    @ObservationIgnored var onAuxSize: (CGSize) -> Void = { _ in }
}
