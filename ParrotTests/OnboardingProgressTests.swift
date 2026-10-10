import XCTest

@testable import Parrot

/// Onboarding without a window: resuming from the saved page, Next and Back
/// at the ends, the missing-permission list behind "Continue Anyway", the
/// push-to-talk presets and completion. The pages themselves, TCC prompts
/// and the live mic meter need a GUI session and are not covered here.
@MainActor
final class OnboardingProgressTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingProgressTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
    }

    func testPagesHaveNoPaywall() {
        XCTAssertEqual(OnboardingPage.allCases, [.welcome, .permissions, .microphone, .model, .tryIt])
        XCTAssertEqual(OnboardingPage.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
    }

    func testResumeClampsTheSavedPage() {
        XCTAssertEqual(OnboardingPage.resumed(from: 0), .welcome)
        XCTAssertEqual(OnboardingPage.resumed(from: 2), .microphone)
        XCTAssertEqual(OnboardingPage.resumed(from: 4), .tryIt)
        XCTAssertEqual(OnboardingPage.resumed(from: 9), .tryIt)
        XCTAssertEqual(OnboardingPage.resumed(from: -3), .welcome)
    }

    func testNextAndBackStopAtTheEnds() {
        XCTAssertEqual(OnboardingPage.welcome.next, .permissions)
        XCTAssertEqual(OnboardingPage.model.next, .tryIt)
        XCTAssertEqual(OnboardingPage.tryIt.next, .tryIt)
        XCTAssertEqual(OnboardingPage.permissions.previous, .welcome)
        XCTAssertEqual(OnboardingPage.welcome.previous, .welcome)
        XCTAssertTrue(OnboardingPage.tryIt.isLast)
        XCTAssertFalse(OnboardingPage.model.isLast)
        XCTAssertEqual(OnboardingPage.welcome.fraction, 0)
        XCTAssertEqual(OnboardingPage.tryIt.fraction, 1)
        XCTAssertEqual(OnboardingPage.microphone.fraction, 0.5)
    }

    func testProgressPersistsAcrossLaunches() {
        let first = makeSettings()
        XCTAssertEqual(first.general.onboardingProgress, 0)
        // What the view writes on each page change.
        first.general.onboardingProgress = OnboardingPage.model.rawValue

        let relaunched = makeSettings()
        XCTAssertEqual(OnboardingPage.resumed(from: relaunched.general.onboardingProgress), .model)
        XCTAssertFalse(relaunched.general.hasCompletedOnboarding)
    }

    func testCompletionSetsTheFlagAndClearsProgress() {
        let settings = makeSettings()
        settings.general.onboardingProgress = OnboardingPage.tryIt.rawValue
        OnboardingFlow.complete(settings.general)

        let relaunched = makeSettings()
        XCTAssertTrue(relaunched.general.hasCompletedOnboarding)
        XCTAssertEqual(relaunched.general.onboardingProgress, 0)
    }

    func testMissingPermissionsListThePagesOrder() {
        XCTAssertEqual(OnboardingFlow.missingPermissions(microphone: true, accessibility: true, inputMonitoring: true), [])
        XCTAssertEqual(
            OnboardingFlow.missingPermissions(microphone: false, accessibility: true, inputMonitoring: false),
            ["Microphone", "Input Monitoring"]
        )
        XCTAssertEqual(
            OnboardingFlow.missingPermissions(microphone: false, accessibility: false, inputMonitoring: false),
            ["Microphone", "Accessibility", "Input Monitoring"]
        )
        let warning = WarningState.permissionsRequired(missing: ["Accessibility"])
        XCTAssertEqual(warning.primaryTitle, "Continue Anyway")
    }

    func testPresetsWritePushToTalk() {
        XCTAssertEqual(OnboardingFlow.presets.map(\.name), ["Right Command", "Right Option", "Fn"])
        XCTAssertEqual(OnboardingFlow.presets.map(\.shortcut.keyCode), [0x36, 0x3D, Shortcut.functionKeyCode])
        XCTAssertTrue(OnboardingFlow.presets.allSatisfy { $0.shortcut.modifiers == 0 && $0.shortcut.mouseButtons.isEmpty })

        let settings = makeSettings()
        let rightCommand = OnboardingFlow.presets[0].shortcut
        settings.hotkeys.setShortcut(rightCommand, for: .pushToTalk)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), rightCommand)
        XCTAssertEqual(OnboardingFlow.preset(matching: settings.hotkeys.shortcut(for: .pushToTalk))?.name, "Right Command")
        XCTAssertEqual(makeSettings().hotkeys.shortcut(for: .pushToTalk), rightCommand)

        XCTAssertNil(OnboardingFlow.preset(matching: .key(0x31, .option)), "a custom key matches no preset")
    }
}
