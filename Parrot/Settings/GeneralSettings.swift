import Foundation
import Observation

// MARK: - AppTheme

/// The app's appearance: follow the system, or pin light or dark.
enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - GeneralSettings

/// App-wide settings: login item, onboarding, the refinement nudge, the
/// menu bar click, Dock icon, theme, typing speed and first-run tips. [UI]
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
        static let showInDock = "parrot.general.showInDock"
        static let theme = "parrot.general.theme"
        static let typingWPM = "parrot.general.typingWPM"
        static let onboardingProgress = "parrot.general.onboardingProgress"
        static let dismissedToasts = "parrot.general.dismissedToasts"
    }

    /// Typing speed assumed until the user takes the typing test.
    static let defaultTypingWPM: Double = 40

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

    /// "Show in Dock". Off (the default) keeps Parrot a menu bar app that
    /// shows a Dock icon only while one of its windows is open.
    var showInDock: Bool {
        didSet { store.set(showInDock, forKey: Key.showInDock) }
    }

    var theme: AppTheme {
        didSet { store.set(theme, forKey: Key.theme) }
    }

    /// The user's typing speed in words per minute, used for "time saved".
    /// The typing speed test writes it.
    var typingWPM: Double {
        didSet { store.set(typingWPM, forKey: Key.typingWPM) }
    }

    /// The onboarding page reached, so a relaunch resumes there.
    var onboardingProgress: Int {
        didSet { store.set(onboardingProgress, forKey: Key.onboardingProgress) }
    }

    /// Ids of first-run tips the user closed.
    var dismissedToasts: Set<String> {
        didSet { store.setEncoded(dismissedToasts.sorted(), forKey: Key.dismissedToasts) }
    }

    private let store: SettingsStore

    init(store: SettingsStore, secrets: SecretStore? = nil) {
        launchAtLogin = store.bool(Key.launchAtLogin, default: false)
        hasCompletedOnboarding = store.bool(Key.hasCompletedOnboarding, default: false)
        successfulDictationCount = store.int(Key.successfulDictationCount, default: 0)
        refinementNudgeDismissed = store.bool(Key.refinementNudgeDismissed, default: false)
        menubarClickRecords = store.bool(Key.menubarClickRecords, default: false)
        showInDock = store.bool(Key.showInDock, default: false)
        theme = store.value(Key.theme, default: AppTheme.system)
        typingWPM = store.double(Key.typingWPM, default: Self.defaultTypingWPM)
        onboardingProgress = store.int(Key.onboardingProgress, default: 0)
        dismissedToasts = Set(store.decoded([String].self, forKey: Key.dismissedToasts) ?? [])
        self.store = store
    }
}
