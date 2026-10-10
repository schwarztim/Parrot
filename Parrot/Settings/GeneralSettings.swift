import Foundation
import Observation

/// App-wide settings: login item, onboarding, the refinement nudge and the
/// menu bar click. [UI]
///
/// Values load in `init` without writing; each property saves in its own
/// didSet. To add a setting, declare it here with no default, load it in
/// `init` before `self.store` is set, and save it in its didSet.
@Observable
final class GeneralSettings {

    private enum Key {
        static let launchAtLogin = "parrot.launchAtLogin"
        static let hasCompletedOnboarding = "parrot.hasCompletedOnboarding"
        static let successfulDictationCount = "parrot.successfulDictationCount"
        static let refinementNudgeDismissed = "parrot.refinementNudgeDismissed"
        static let menubarClickRecords = "parrot.general.menubarClickRecords"
    }

    /// Saved preference only. The Launch at Login toggle reads and writes the
    /// system login item through `AppState.setLaunchAtLogin(_:)`.
    var launchAtLogin: Bool {
        didSet { store.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { store.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Count of successful dictations, used to time the one-time AI Refinement
    /// discovery nudge (it appears after a handful of dictations).
    var successfulDictationCount: Int {
        didSet { store.set(successfulDictationCount, forKey: Key.successfulDictationCount) }
    }

    /// True once the user has acted on or dismissed the refinement nudge.
    var refinementNudgeDismissed: Bool {
        didSet { store.set(refinementNudgeDismissed, forKey: Key.refinementNudgeDismissed) }
    }

    /// "Start Recording on Menubar Click": left click on the menu bar icon
    /// starts or stops a recording and right click opens the menu. Off, any
    /// click opens the menu.
    var menubarClickRecords: Bool {
        didSet { store.set(menubarClickRecords, forKey: Key.menubarClickRecords) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        launchAtLogin = store.bool(Key.launchAtLogin, default: false)
        hasCompletedOnboarding = store.bool(Key.hasCompletedOnboarding, default: false)
        successfulDictationCount = store.int(Key.successfulDictationCount, default: 0)
        refinementNudgeDismissed = store.bool(Key.refinementNudgeDismissed, default: false)
        menubarClickRecords = store.bool(Key.menubarClickRecords, default: false)
        self.store = store
    }
}
