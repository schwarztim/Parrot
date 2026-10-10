import ApplicationServices
import XCTest

@testable import Parrot

/// Auto-paste resolution, the Shift submit decision, restore timing and the
/// delivery stages that run without Accessibility.
@MainActor
final class DeliverPolicyTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var pasteboard: FakePasteboard!
    private var scheduler: ManualScheduler!
    private var toasts: [String] = []
    private var services: AppServices!

    override func setUp() {
        super.setUp()
        suiteName = "parrot-deliverpolicytests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())

        // A temp path that is never written: delivery never saves vocabulary.
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-deliverpolicytests-\(UUID().uuidString)")
            .appendingPathComponent("vocabulary.json")
        services = AppServices(vocabulary: VocabularyManager(storageURL: storage))
        services.settings = settings
        services.showTransientError = { [unowned self] message in self.toasts.append(message) }

        pasteboard = FakePasteboard()
        pasteboard.externalCopy("mine")
        scheduler = ManualScheduler()
        services.output.clipboard = ClipboardService(pasteboard: pasteboard, scheduler: scheduler)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func policy(
        mode: Bool? = nil,
        global: Bool = true,
        simulate: Bool = false,
        trusted: Bool = true,
        shift: Bool = false,
        autoSubmit: Bool = false,
        behaviour: ClipboardBehaviour = .keep,
        delay: TimeInterval = 1.0,
        history: Bool = false
    ) -> DeliveryPolicy {
        DeliveryPolicy(
            modeAutoPaste: mode,
            globalAutoPaste: global,
            simulateKeypresses: simulate,
            accessibilityTrusted: trusted,
            shiftHeldAtStop: shift,
            autoSubmitWithShift: autoSubmit,
            clipboardBehaviour: behaviour,
            restoreDelay: delay,
            clipboardHistory: history
        )
    }

    // MARK: - Auto-Paste Resolution

    func testModeOverrideWinsOverTheGlobalSwitch() {
        XCTAssertTrue(DeliveryPolicy.effectiveAutoPaste(mode: nil, global: true))
        XCTAssertFalse(DeliveryPolicy.effectiveAutoPaste(mode: nil, global: false))
        XCTAssertTrue(DeliveryPolicy.effectiveAutoPaste(mode: true, global: false))
        XCTAssertFalse(DeliveryPolicy.effectiveAutoPaste(mode: false, global: true))
    }

    func testAutoPasteOffLeavesTheDictationAndNeverSubmits() {
        let off = policy(mode: false, shift: true, autoSubmit: true)
        XCTAssertEqual(off.method, .clipboardOnly(.autoPasteOff))
        XCTAssertFalse(off.delivers)
        XCTAssertNil(off.restoreDelay, "the clipboard keeps the dictation whatever the behaviour")
        XCTAssertFalse(off.pressReturn)
    }

    func testWithoutAccessibilityTheTextStaysOnTheClipboard() {
        let untrusted = policy(trusted: false, shift: true, autoSubmit: true)
        XCTAssertEqual(untrusted.method, .clipboardOnly(.untrusted))
        XCTAssertNil(untrusted.restoreDelay)
        XCTAssertFalse(untrusted.pressReturn)
    }

    // MARK: - Restore Timing

    func testPasteRestoresAfterTheDelayWhenKeeping() {
        XCTAssertEqual(policy().method, .paste)
        XCTAssertEqual(policy().restoreDelay, 1.0)
        XCTAssertEqual(policy(delay: 2.5).restoreDelay, 2.5)
        XCTAssertEqual(policy(delay: -1).restoreDelay, 0)
    }

    func testReplaceNeverRestores() {
        XCTAssertNil(policy(behaviour: .replace).restoreDelay)
        XCTAssertNil(policy(simulate: true, behaviour: .replace).restoreDelay)
    }

    func testTypingRestoresWithoutTheDelay() {
        let typed = policy(simulate: true, delay: 1.0)
        XCTAssertEqual(typed.method, .type)
        XCTAssertEqual(typed.restoreDelay, 0)
    }

    func testHistorySettingControlsTheTransientMarker() {
        XCTAssertTrue(policy(history: false).markTransient)
        XCTAssertFalse(policy(history: true).markTransient)
    }

    // MARK: - Shift Submit

    func testReturnOnlyWithShiftHeldAndTheSettingOn() {
        XCTAssertTrue(policy(shift: true, autoSubmit: true).pressReturn)
        XCTAssertFalse(policy(shift: false, autoSubmit: true).pressReturn)
        XCTAssertFalse(policy(shift: true, autoSubmit: false).pressReturn)
        XCTAssertFalse(policy(shift: false, autoSubmit: false).pressReturn)
        XCTAssertTrue(policy(simulate: true, shift: true, autoSubmit: true).pressReturn)
    }

    // MARK: - Settings

    func testDefaultsFromSettings() {
        let output = settings.output
        XCTAssertTrue(output.autoPaste)
        XCTAssertEqual(output.clipboardBehaviour, .keep)
        XCTAssertEqual(output.restoreDelay, 1.0)
        XCTAssertFalse(output.clipboardHistory)
        XCTAssertFalse(output.simulateKeypresses)
        XCTAssertFalse(output.autoSubmitWithShift)
        XCTAssertNil(defaults.object(forKey: "parrot.output.autoPaste"), "loading writes nothing")

        let fromSettings = DeliveryPolicy(settings: output, mode: nil, shiftHeldAtStop: false, accessibilityTrusted: true)
        XCTAssertEqual(fromSettings, policy())
    }

    func testSettingsPersistUnderOutputKeys() {
        settings.output.clipboardBehaviour = .replace
        settings.output.autoSubmitWithShift = true
        XCTAssertEqual(defaults.string(forKey: "parrot.output.clipboardBehaviour"), "replace")
        XCTAssertTrue(defaults.bool(forKey: "parrot.output.autoSubmitWithShift"))

        let reloaded = OutputSettings(store: SettingsStore(defaults: defaults))
        XCTAssertEqual(reloaded.clipboardBehaviour, .replace)
        XCTAssertTrue(reloaded.autoSubmitWithShift)
    }

    // MARK: - Paste Confirmation

    func testPasteConfirmation() {
        let before = FieldSnapshot(role: "AXTextArea", isEditable: true, value: "Hello")
        let changed = FieldSnapshot(role: "AXTextArea", isEditable: true, value: "Hello world")
        let sameLength = FieldSnapshot(role: "AXTextArea", isEditable: true, value: "Jello")
        let unreadable = FieldSnapshot(role: "AXWebArea", isEditable: true, value: nil)

        XCTAssertEqual(PasteConfirmation.evaluate(before: before, after: changed, sameElement: true), .confirmed)
        XCTAssertEqual(PasteConfirmation.evaluate(before: before, after: sameLength, sameElement: true), .confirmed)
        XCTAssertEqual(PasteConfirmation.evaluate(before: before, after: before, sameElement: true), .unconfirmed)
        XCTAssertEqual(PasteConfirmation.evaluate(before: before, after: changed, sameElement: false), .redirected)
        XCTAssertEqual(PasteConfirmation.evaluate(before: before, after: unreadable, sameElement: true), .unavailable)
        XCTAssertEqual(PasteConfirmation.evaluate(before: nil, after: changed, sameElement: true), .unavailable)
        XCTAssertEqual(PasteConfirmation.evaluate(before: before, after: nil, sameElement: false), .unavailable)
    }

    // MARK: - DeliverStage (paths that post no keystrokes)

    private func session(_ text: String, mode: Mode? = nil, source: DictationSource = .live) -> DictationSession {
        let session = DictationSession(trigger: .pushToTalk, mode: mode, source: source)
        session.text = text
        return session
    }

    func testAutoPasteOffCopiesOnlyAndLeavesTheDictation() async throws {
        settings.output.autoPaste = false
        let session = session("hello there")

        let result = try await DeliverStage(services: services).run(session)

        XCTAssertEqual(result, .continue, "PostAction and Persist still run")
        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(pasteboard.text, "hello there")
        XCTAssertTrue(pasteboard.types.contains(PasteboardMarker.transient))
        XCTAssertEqual(scheduler.activeDelays, [], "no restore without a paste")
        XCTAssertEqual(toasts, [])
        XCTAssertEqual(services.live.resultText, "hello there")
    }

    func testModeOverrideOffBeatsGlobalOn() async throws {
        settings.output.autoPaste = true
        settings.output.clipboardHistory = true
        let session = session("from a mode", mode: Mode(name: "Quiet", autoPaste: false))

        _ = try await DeliverStage(services: services).run(session)

        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(pasteboard.text, "from a mode")
        XCTAssertFalse(pasteboard.types.contains(PasteboardMarker.transient), "history on: no marker")
    }

    func testEmptyTextFinishesEmptyAndLeavesTheClipboard() async throws {
        let session = session("  \n ")

        let result = try await DeliverStage(services: services).run(session)

        XCTAssertEqual(result, .finish(.empty))
        XCTAssertEqual(pasteboard.text, "mine")
    }

    func testFileRunCopiesWithoutPasting() async throws {
        let session = session("from a file", source: .file(URL(fileURLWithPath: "/tmp/clip.wav")))

        _ = try await DeliverStage(services: services).run(session)

        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(pasteboard.text, "from a file")
        XCTAssertEqual(scheduler.activeDelays, [])
    }

    func testWithoutAccessibilityCopiesAndTellsTheUser() async throws {
        try XCTSkipIf(AXIsProcessTrusted(), "this process is trusted, so the stage would really paste")
        let session = session("needs access")

        _ = try await DeliverStage(services: services).run(session)

        XCTAssertEqual(session.outcome, .copiedOnly)
        XCTAssertEqual(pasteboard.text, "needs access")
        XCTAssertEqual(scheduler.activeDelays, [])
        XCTAssertEqual(toasts.count, 1)
    }

    // MARK: - FormatOutputStage

    func testFormatLeavesTextAloneWithoutCaretContext() async throws {
        let session = session("Hello there")

        _ = try await FormatOutputStage(services: services).run(session)

        XCTAssertEqual(session.text, "Hello there")
        XCTAssertFalse(session.outputNeedsLeadingSpace)
    }

    func testFormatAppliesThePrefetchedCaretContext() async throws {
        let session = session("Sat down")
        let element = AXUIElementCreateSystemWide()
        let target = PasteTarget(
            element: element, pid: 0, field: FieldSnapshot(value: "The cat"),
            cursor: CursorContext(before: "The cat", after: "")
        )
        session.pasteTargetPrefetch = Task { target }

        _ = try await FormatOutputStage(services: services).run(session)

        XCTAssertEqual(session.text, "sat down")
        XCTAssertTrue(session.outputNeedsLeadingSpace)
    }

    func testFormatRespectsTheModeSwitch() async throws {
        let session = session("Sat down", mode: Mode(name: "Lower", autocapitalizeInsert: false))
        let target = PasteTarget(
            element: AXUIElementCreateSystemWide(), pid: 0, field: FieldSnapshot(value: "The cat"),
            cursor: CursorContext(before: "The cat", after: "")
        )
        session.pasteTargetPrefetch = Task { target }

        _ = try await FormatOutputStage(services: services).run(session)

        XCTAssertEqual(session.text, "Sat down")
    }
}
