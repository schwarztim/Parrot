import AppKit
import Foundation

/// Every named shortcut, in Superwhisper's internal order. [TRG]
///
/// The raw value is the name in both apps: Parrot saves each one under
/// `parrot.hotkeys.<name>`, Superwhisper under `KeyboardShortcuts_<name>`.
enum ShortcutName: String, CaseIterable, Codable, Sendable, Identifiable {
    case pushToTalk
    case toggleRecording
    case clickToTalk
    case changeMode
    case cancelRecording
    case navigateUp
    case navigateDown
    case actionSubmit
    case firstMode
    case secondMode
    case thirdMode
    case fourthMode
    case fifthMode
    case sixthMode
    case seventhMode
    case eighthMode
    case ninthMode
    case tenthMode

    var id: String { rawValue }

    /// When the shortcut's key is live.
    enum Scope: Sendable {
        /// Always armed.
        case global
        /// Armed while a recording is starting or running, or while the mode
        /// switcher is shown (where it closes the switcher).
        case whileRecording
        /// Armed only while the mode switcher is shown.
        case whileSwitcherShown
    }

    var scope: Scope {
        switch self {
        case .pushToTalk, .toggleRecording, .clickToTalk, .changeMode: return .global
        case .cancelRecording: return .whileRecording
        default: return .whileSwitcherShown
        }
    }

    /// Shown in Settings with a recorder.
    var isConfigurable: Bool {
        switch self {
        case .pushToTalk, .toggleRecording, .clickToTalk, .changeMode, .cancelRecording: return true
        default: return false
        }
    }

    /// The configurable shortcuts in the order Settings lists them.
    static let configurable: [ShortcutName] = [
        .toggleRecording, .pushToTalk, .changeMode, .cancelRecording, .clickToTalk,
    ]

    var title: String {
        switch self {
        case .pushToTalk: return "Push to Talk"
        case .toggleRecording: return "Toggle Recording"
        case .clickToTalk: return "Mouse Shortcut"
        case .changeMode: return "Change Mode"
        case .cancelRecording: return "Cancel Recording"
        case .navigateUp: return "Move Up"
        case .navigateDown: return "Move Down"
        case .actionSubmit: return "Confirm"
        default: return "Mode \((modeSlot ?? 0) + 1)"
        }
    }

    var summary: String {
        switch self {
        case .pushToTalk: return "Hold to record, release when done"
        case .toggleRecording: return "Starts and stops recordings"
        case .clickToTalk: return "Use the scroll wheel click or another mouse button. Tap to toggle, or hold and release when done."
        case .changeMode: return "Activates the mode switcher"
        case .cancelRecording: return "Discards the active recording"
        case .navigateUp: return "Moves the mode switcher selection up"
        case .navigateDown: return "Moves the mode switcher selection down"
        case .actionSubmit: return "Confirms the mode switcher selection"
        default: return "Picks this mode in the mode switcher"
        }
    }

    /// Position in the mode list for `firstMode` (0) through `tenthMode` (9).
    var modeSlot: Int? {
        switch self {
        case .firstMode: return 0
        case .secondMode: return 1
        case .thirdMode: return 2
        case .fourthMode: return 3
        case .fifthMode: return 4
        case .sixthMode: return 5
        case .seventhMode: return 6
        case .eighthMode: return 7
        case .ninthMode: return 8
        case .tenthMode: return 9
        default: return nil
        }
    }

    /// The built-in binding from the spec's shortcut table. Superwhisper
    /// ships no push-to-talk key; Parrot keeps its Right Option default.
    var defaultShortcut: Shortcut {
        switch self {
        case .pushToTalk: return .key(0x3D)                            // Right Option
        case .toggleRecording: return .key(0x31, .option)              // Option+Space
        case .clickToTalk: return .none
        case .changeMode: return .key(0x28, [.option, .shift])         // Option+Shift+K
        case .cancelRecording: return .key(Shortcut.escapeKeyCode)     // Escape
        case .navigateUp: return .key(0x7E)
        case .navigateDown: return .key(0x7D)
        case .actionSubmit: return .key(0x24)                          // Return
        case .firstMode: return .key(0x12)                             // 1
        case .secondMode: return .key(0x13)
        case .thirdMode: return .key(0x14)
        case .fourthMode: return .key(0x15)
        case .fifthMode: return .key(0x17)
        case .sixthMode: return .key(0x16)
        case .seventhMode: return .key(0x1A)
        case .eighthMode: return .key(0x1C)
        case .ninthMode: return .key(0x19)
        case .tenthMode: return .key(0x1D)                             // 0
        }
    }

    /// UserDefaults key for the saved binding.
    var defaultsKey: String { "parrot.hotkeys.\(rawValue)" }
}

/// Anything a shortcut can be assigned to: a named shortcut or a mode.
enum ShortcutTarget: Hashable, Sendable {
    case name(ShortcutName)
    case mode(UUID)

    /// Stable id for the listener registration.
    var registrationID: String {
        switch self {
        case .name(let name): return name.rawValue
        case .mode(let id): return "mode-\(id.uuidString)"
        }
    }

    init?(registrationID: String) {
        if let name = ShortcutName(rawValue: registrationID) {
            self = .name(name)
        } else if registrationID.hasPrefix("mode-"),
                  let id = UUID(uuidString: String(registrationID.dropFirst(5))) {
            self = .mode(id)
        } else {
            return nil
        }
    }
}

/// The bindings to register for one moment, after arming and de-duplication.
struct HotkeyPlan: Equatable, Sendable {
    var bindings: [ShortcutTarget: Shortcut] = [:]
    /// Push to Talk and Toggle Recording are the same key. Only Push to Talk
    /// is registered and its hold threshold becomes 1000 ms.
    var pushToTalkSharesToggleKey = false
}

/// Rules over the named shortcuts: arming, conflicts, and what to register. [TRG]
///
/// Values are saved in `HotkeySettings` (`shortcut(for:)`,
/// `setShortcut(_:for:)`). The Superwhisper decoder is `SuperwhisperShortcut`.
enum ShortcutRegistry {

    /// Names whose keys are live. Global names always are; Cancel while a
    /// recording is starting or running or the switcher is shown; switcher
    /// keys only while the switcher is shown.
    static func armedNames(isRecording: Bool, switcherShown: Bool) -> Set<ShortcutName> {
        Set(ShortcutName.allCases.filter { name in
            switch name.scope {
            case .global: return true
            case .whileRecording: return isRecording || switcherShown
            case .whileSwitcherShown: return switcherShown
            }
        })
    }

    /// The target that already uses `candidate`, or nil when it is free.
    /// Push to Talk and Toggle Recording may share one key (tap toggles,
    /// a hold of 1 s or more stops on release). An empty candidate never
    /// conflicts.
    static func conflict(
        for candidate: Shortcut,
        assigningTo target: ShortcutTarget,
        in current: [ShortcutTarget: Shortcut]
    ) -> ShortcutTarget? {
        guard !candidate.isEmpty else { return nil }
        let sharedPair: Set<ShortcutTarget> = [.name(.pushToTalk), .name(.toggleRecording)]
        // Check in a fixed order so the answer does not depend on hashing.
        let others = current
            .filter { $0.key != target && !$0.value.isEmpty }
            .sorted { order($0.key) < order($1.key) }
        for (other, shortcut) in others where shortcut.overlaps(candidate) {
            if sharedPair.contains(target), sharedPair.contains(other) { continue }
            return other
        }
        return nil
    }

    /// Every target's current binding: the named shortcuts plus each mode
    /// that has a shortcut.
    static func targets(
        shortcuts: [ShortcutName: Shortcut],
        modes: [(id: UUID, shortcut: Shortcut)]
    ) -> [ShortcutTarget: Shortcut] {
        var result: [ShortcutTarget: Shortcut] = [:]
        for (name, shortcut) in shortcuts { result[.name(name)] = shortcut }
        for mode in modes { result[.mode(mode.id)] = mode.shortcut }
        return result
    }

    /// What to register right now. Unarmed and empty bindings are left out.
    /// When two armed bindings fire on the same input, the earlier one in
    /// `ShortcutName` order wins and modes come last.
    static func plan(
        shortcuts: [ShortcutName: Shortcut],
        modes: [(id: UUID, shortcut: Shortcut)],
        isRecording: Bool,
        switcherShown: Bool
    ) -> HotkeyPlan {
        let armed = armedNames(isRecording: isRecording, switcherShown: switcherShown)
        var plan = HotkeyPlan()
        var taken: [Shortcut] = []

        let ptt = shortcuts[.pushToTalk] ?? .none
        let toggle = shortcuts[.toggleRecording] ?? .none
        plan.pushToTalkSharesToggleKey = !ptt.isEmpty && ptt.overlaps(toggle)

        func add(_ target: ShortcutTarget, _ shortcut: Shortcut) {
            guard !shortcut.isEmpty, !taken.contains(where: { $0.overlaps(shortcut) }) else { return }
            plan.bindings[target] = shortcut
            taken.append(shortcut)
        }

        for name in ShortcutName.allCases where armed.contains(name) {
            add(.name(name), shortcuts[name] ?? name.defaultShortcut)
        }
        for mode in modes {
            add(.mode(mode.id), mode.shortcut)
        }
        return plan
    }

    /// What a recorder shows after "Already in use by": the shortcut's title
    /// or "the <name> mode". Nil when `candidate` is free.
    static func conflictName(
        for candidate: Shortcut,
        assigningTo target: ShortcutTarget,
        hotkeys: HotkeySettings,
        modes: [Mode]
    ) -> String? {
        let modeShortcuts = modes.compactMap { mode in
            mode.shortcut.map { (id: mode.id, shortcut: Shortcut(mode: $0)) }
        }
        let current = targets(shortcuts: hotkeys.allShortcuts, modes: modeShortcuts)
        switch conflict(for: candidate, assigningTo: target, in: current) {
        case .name(let name)?:
            return name.title
        case .mode(let id)?:
            return "the \(modes.first { $0.id == id }?.name ?? "other") mode"
        case nil:
            return nil
        }
    }

    private static func order(_ target: ShortcutTarget) -> Int {
        switch target {
        case .name(let name): return ShortcutName.allCases.firstIndex(of: name) ?? 0
        case .mode: return ShortcutName.allCases.count
        }
    }
}
