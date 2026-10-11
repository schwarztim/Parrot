import Foundation

/// Which hotkey produced a press. [TRG]
enum TriggerSource: Hashable, Sendable {
    case pushToTalk
    case toggleRecording
    case clickToTalk
    /// A mode's own shortcut.
    case mode(UUID)

    var recordingTrigger: RecordingTrigger {
        switch self {
        case .pushToTalk: return .pushToTalk
        case .toggleRecording: return .toggle
        case .clickToTalk: return .clickToTalk
        case .mode: return .modeShortcut
        }
    }

    var modeID: UUID? {
        if case .mode(let id) = self { return id }
        return nil
    }

    /// Push to Talk and mouse buttons use the hold rule; the rest toggle.
    var usesHoldRule: Bool { self == .pushToTalk || self == .clickToTalk }
}

/// One hotkey event.
enum TriggerInput: Equatable, Sendable {
    case down(TriggerSource)
    case up(TriggerSource)
    /// Another key went down while this lone modifier key was held, so the
    /// press was a key combination, not a trigger.
    case interrupted(TriggerSource)
}

/// The controller as the state machine sees it.
enum TriggerRecordingStatus: Equatable, Sendable {
    case idle
    /// Starting or recording, with the trigger that started it.
    case active(RecordingTrigger)
    /// Stopping or processing. Presses are ignored.
    case busy
}

/// What to ask the controller for.
enum TriggerCommand: Equatable, Sendable {
    case start(RecordingTrigger, mode: UUID?)
    case stop(RecordingTrigger)
    case cancel
}

/// Per-source shape of the binding.
struct TriggerOptions: Equatable, Sendable {
    /// A lone modifier key. Toggle-style sources fire when it is released
    /// with no other key pressed, so typing a combination never toggles.
    var isModifierOnly = false
    /// Fires on the second of two quick taps instead of on each press.
    var doubleTap = false
}

/// Decides what each hotkey press does. Pure: the clock is injected and
/// the controller status is passed in with every event. [TRG]
///
/// - Push to Talk: press starts. Release after a hold of at least 500 ms
///   stops (1000 ms when Push to Talk and Toggle Recording are the same key).
///   A shorter tap keeps recording, and the next press stops. A press while
///   another trigger's recording runs is ignored.
/// - Mouse button (click to talk): the same, always with 500 ms.
/// - Toggle Recording and mode shortcuts: each press starts when idle and
///   stops when recording. A lone modifier fires on release instead.
/// - Double tap: a first short tap arms the source; a second press inside
///   `doubleTapWindow` toggles.
/// - A lone modifier that started a recording and is then used in a key
///   combination within its hold threshold cancels that recording.
struct TriggerStateMachine {

    static let holdThreshold: TimeInterval = 0.5
    static let sharedKeyHoldThreshold: TimeInterval = 1.0
    static let clickHoldThreshold: TimeInterval = 0.5
    static let doubleTapWindow: TimeInterval = 0.4

    var options: [TriggerSource: TriggerOptions] = [:]
    /// Push to Talk and Toggle Recording are bound to the same key.
    var pushToTalkSharesToggleKey = false

    private struct Hold {
        var downAt: TimeInterval
        /// This press started the recording.
        var startedRecording = false
        var interrupted = false
        /// This press already fired (a stop, or a double tap's second press).
        var fired = false
    }

    private let now: () -> TimeInterval
    /// Keys and buttons that are down now.
    private var holds: [TriggerSource: Hold] = [:]
    /// The hold-rule source that started the live recording.
    private var owner: TriggerSource?
    /// When each double-tap source was armed by a first tap.
    private var armedAt: [TriggerSource: TimeInterval] = [:]

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// The release threshold for a hold-rule source.
    func holdThreshold(for source: TriggerSource) -> TimeInterval {
        switch source {
        case .clickToTalk: return Self.clickHoldThreshold
        case .pushToTalk: return pushToTalkSharesToggleKey ? Self.sharedKeyHoldThreshold : Self.holdThreshold
        default: return Self.holdThreshold
        }
    }

    /// True while a first tap waits for its second (UI feedback).
    func isArmed(_ source: TriggerSource) -> Bool {
        guard let armed = armedAt[source] else { return false }
        return now() - armed <= Self.doubleTapWindow
    }

    /// True when the live recording was started by `source` and continues
    /// after a short tap.
    func isLatched(_ source: TriggerSource) -> Bool {
        owner == source && holds[source] == nil
    }

    mutating func handle(_ input: TriggerInput, status: TriggerRecordingStatus) -> TriggerCommand? {
        syncOwner(with: status)
        switch input {
        case .down(let source):
            guard holds[source] == nil else { return nil } // key repeat
            if options[source]?.doubleTap == true { return doubleTapDown(source, status) }
            return source.usesHoldRule ? holdDown(source, status) : toggleDown(source, status)

        case .up(let source):
            guard let hold = holds.removeValue(forKey: source) else { return nil }
            if options[source]?.doubleTap == true { return doubleTapUp(source, hold) }
            return source.usesHoldRule ? holdUp(source, hold, status) : toggleUp(source, hold, status)

        case .interrupted(let source):
            guard var hold = holds[source], !hold.interrupted else { return nil }
            if source.usesHoldRule, options[source]?.doubleTap != true {
                // Only a combination typed right after the press that
                // started the recording cancels it. Later keys are ignored,
                // so a long dictation is never thrown away.
                guard hold.startedRecording, owner == source, case .active = status,
                      now() - hold.downAt < holdThreshold(for: source) else { return nil }
                hold.interrupted = true
                holds[source] = hold
                owner = nil
                return .cancel
            }
            hold.interrupted = true
            holds[source] = hold
            return nil
        }
    }

    // MARK: - Hold Rule

    private mutating func holdDown(_ source: TriggerSource, _ status: TriggerRecordingStatus) -> TriggerCommand? {
        var hold = Hold(downAt: now())
        defer { holds[source] = hold }
        switch status {
        case .idle:
            hold.startedRecording = true
            owner = source
            return .start(source.recordingTrigger, mode: source.modeID)
        case .active:
            // The second press after a tap stops; another trigger's
            // recording is left alone.
            guard owner == source else { return nil }
            hold.fired = true
            owner = nil
            return .stop(source.recordingTrigger)
        case .busy:
            return nil
        }
    }

    private mutating func holdUp(_ source: TriggerSource, _ hold: Hold, _ status: TriggerRecordingStatus) -> TriggerCommand? {
        guard hold.startedRecording, !hold.interrupted, owner == source, case .active = status else { return nil }
        guard now() - hold.downAt >= holdThreshold(for: source) else {
            return nil // a tap: keep recording until the next press
        }
        owner = nil
        return .stop(source.recordingTrigger)
    }

    // MARK: - Toggle

    private mutating func toggleDown(_ source: TriggerSource, _ status: TriggerRecordingStatus) -> TriggerCommand? {
        holds[source] = Hold(downAt: now())
        if options[source]?.isModifierOnly == true { return nil } // fires on release
        return fire(source, status)
    }

    private mutating func toggleUp(_ source: TriggerSource, _ hold: Hold, _ status: TriggerRecordingStatus) -> TriggerCommand? {
        guard options[source]?.isModifierOnly == true, !hold.interrupted else { return nil }
        return fire(source, status)
    }

    private mutating func fire(_ source: TriggerSource, _ status: TriggerRecordingStatus) -> TriggerCommand? {
        switch status {
        case .idle:
            owner = nil
            return .start(source.recordingTrigger, mode: source.modeID)
        case .active:
            owner = nil
            return .stop(source.recordingTrigger)
        case .busy:
            return nil
        }
    }

    // MARK: - Double Tap

    private mutating func doubleTapDown(_ source: TriggerSource, _ status: TriggerRecordingStatus) -> TriggerCommand? {
        var hold = Hold(downAt: now())
        defer { holds[source] = hold }
        let wasArmed = isArmed(source)
        armedAt[source] = nil
        guard wasArmed else { return nil }
        hold.fired = true
        return fire(source, status)
    }

    private mutating func doubleTapUp(_ source: TriggerSource, _ hold: Hold) -> TriggerCommand? {
        if !hold.interrupted, !hold.fired, now() - hold.downAt <= Self.doubleTapWindow {
            armedAt[source] = now()
        }
        return nil
    }

    // MARK: - Status

    /// Forgets ownership once the recording it started has ended or been
    /// replaced by another trigger's.
    private mutating func syncOwner(with status: TriggerRecordingStatus) {
        guard let current = owner else { return }
        switch status {
        case .idle, .busy:
            owner = nil
        case .active(let trigger):
            if trigger != current.recordingTrigger { owner = nil }
        }
    }
}

/// Keyboard movement in the mode switcher. [TRG]
enum ModeSwitcherNavigation {

    /// The index after moving `delta` rows from `current`, wrapping around.
    /// From no selection, down picks the first row and up the last.
    static func index(from current: Int?, moving delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else {
            return delta >= 0 ? 0 : count - 1
        }
        return ((current + delta) % count + count) % count
    }

    /// The row for a digit slot (0 for key 1 through 9 for key 0), or nil
    /// when there are fewer modes.
    static func index(forSlot slot: Int, count: Int) -> Int? {
        (0..<count).contains(slot) ? slot : nil
    }
}
