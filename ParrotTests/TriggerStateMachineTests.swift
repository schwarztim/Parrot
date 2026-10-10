import XCTest

@testable import Parrot

/// Every press, release and timing edge of the trigger state machine, on a
/// fake clock.
final class TriggerStateMachineTests: XCTestCase {

    private final class FakeClock {
        var now: TimeInterval = 1000
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var clock: FakeClock!
    private var machine: TriggerStateMachine!
    /// What the controller would report after the commands so far.
    private var status: TriggerRecordingStatus = .idle

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        let clock = clock!
        machine = TriggerStateMachine(now: { clock.now })
        status = .idle
    }

    /// Feeds one input and applies the command to the fake controller status.
    @discardableResult
    private func send(_ input: TriggerInput) -> TriggerCommand? {
        let command = machine.handle(input, status: status)
        switch command {
        case .start(let trigger, _)?: status = .active(trigger)
        case .stop?: status = .busy
        case .cancel?: status = .idle
        case nil: break
        }
        return command
    }

    private func finishProcessing() { status = .idle }

    // MARK: - Push to Talk

    func testHoldAtThresholdStopsOnRelease() {
        XCTAssertEqual(send(.down(.pushToTalk)), .start(.pushToTalk, mode: nil))
        clock.advance(0.5)
        XCTAssertEqual(send(.up(.pushToTalk)), .stop(.pushToTalk))
    }

    func testTapKeepsRecordingAndNextPressStops() {
        send(.down(.pushToTalk))
        clock.advance(0.499)
        XCTAssertNil(send(.up(.pushToTalk)), "a tap under 500 ms keeps recording")
        XCTAssertTrue(machine.isLatched(.pushToTalk))
        clock.advance(3)
        XCTAssertEqual(send(.down(.pushToTalk)), .stop(.pushToTalk))
        clock.advance(2)
        XCTAssertNil(send(.up(.pushToTalk)), "the release after the stopping press does nothing")
    }

    func testSharedKeyNeedsOneSecondHold() {
        machine.pushToTalkSharesToggleKey = true
        XCTAssertEqual(machine.holdThreshold(for: .pushToTalk), 1.0)
        send(.down(.pushToTalk))
        clock.advance(0.9)
        XCTAssertNil(send(.up(.pushToTalk)), "under 1 s on a shared key is a toggle tap")
        XCTAssertEqual(send(.down(.pushToTalk)), .stop(.pushToTalk))
        send(.up(.pushToTalk))
        finishProcessing()

        send(.down(.pushToTalk))
        clock.advance(1.0)
        XCTAssertEqual(send(.up(.pushToTalk)), .stop(.pushToTalk))
    }

    func testDistinctKeysUseHalfSecond() {
        XCTAssertEqual(machine.holdThreshold(for: .pushToTalk), 0.5)
        XCTAssertEqual(machine.holdThreshold(for: .clickToTalk), 0.5)
    }

    func testPressDuringAnotherTriggersRecordingIsIgnored() {
        status = .active(.url)
        XCTAssertNil(send(.down(.pushToTalk)))
        clock.advance(2)
        XCTAssertNil(send(.up(.pushToTalk)))
        XCTAssertEqual(status, .active(.url))
    }

    func testPressWhileProcessingIsIgnored() {
        status = .busy
        XCTAssertNil(send(.down(.pushToTalk)))
        finishProcessing()
        clock.advance(1)
        XCTAssertNil(send(.up(.pushToTalk)), "the release of an ignored press never stops")
    }

    func testKeyRepeatIsIgnored() {
        send(.down(.pushToTalk))
        XCTAssertNil(send(.down(.pushToTalk)))
        clock.advance(0.6)
        XCTAssertEqual(send(.up(.pushToTalk)), .stop(.pushToTalk))
    }

    func testStopFromElsewhereEndsOwnership() {
        send(.down(.pushToTalk))
        clock.advance(0.1)
        send(.up(.pushToTalk)) // latched
        status = .idle         // stopped from the menu and finished
        XCTAssertEqual(send(.down(.pushToTalk)), .start(.pushToTalk, mode: nil), "a new press starts again")
    }

    func testFailedStartForgetsThePress() {
        send(.down(.pushToTalk))
        status = .idle // the mic failed to open
        clock.advance(1)
        XCTAssertNil(send(.up(.pushToTalk)))
    }

    func testToggleStopsAPushToTalkRecordingAndTheReleaseIsQuiet() {
        send(.down(.pushToTalk))
        clock.advance(0.2)
        XCTAssertEqual(send(.down(.toggleRecording)), .stop(.toggle))
        send(.up(.toggleRecording))
        clock.advance(1)
        XCTAssertNil(send(.up(.pushToTalk)))
    }

    func testKeyCombinationCancelsAModifierStartedRecording() {
        send(.down(.pushToTalk))
        clock.advance(0.1)
        XCTAssertEqual(send(.interrupted(.pushToTalk)), .cancel)
        XCTAssertNil(send(.interrupted(.pushToTalk)), "only once per press")
        XCTAssertNil(send(.up(.pushToTalk)))
        XCTAssertEqual(status, .idle)
    }

    func testKeyAfterTheHoldThresholdIsIgnored() {
        send(.down(.pushToTalk))
        clock.advance(0.6)
        XCTAssertNil(send(.interrupted(.pushToTalk)), "a long dictation is never thrown away")
        XCTAssertEqual(send(.up(.pushToTalk)), .stop(.pushToTalk), "the release still stops")
    }

    // MARK: - Toggle Recording

    func testTogglePressStartsAndNextPressStops() {
        XCTAssertEqual(send(.down(.toggleRecording)), .start(.toggle, mode: nil))
        XCTAssertNil(send(.up(.toggleRecording)))
        clock.advance(5)
        XCTAssertEqual(send(.down(.toggleRecording)), .stop(.toggle))
        XCTAssertNil(send(.up(.toggleRecording)))
    }

    func testToggleStopsAnyTriggersRecording() {
        status = .active(.menu)
        XCTAssertEqual(send(.down(.toggleRecording)), .stop(.toggle))
    }

    func testToggleHoldDoesNotStopOnRelease() {
        send(.down(.toggleRecording))
        clock.advance(3)
        XCTAssertNil(send(.up(.toggleRecording)), "toggle is a pure toggle")
        XCTAssertEqual(status, .active(.toggle))
    }

    func testLoneModifierToggleFiresOnCleanRelease() {
        machine.options[.toggleRecording] = TriggerOptions(isModifierOnly: true)
        XCTAssertNil(send(.down(.toggleRecording)))
        XCTAssertEqual(send(.up(.toggleRecording)), .start(.toggle, mode: nil))
        XCTAssertNil(send(.down(.toggleRecording)))
        XCTAssertNil(send(.interrupted(.toggleRecording)))
        XCTAssertNil(send(.up(.toggleRecording)), "Control+C while recording does not stop")
        XCTAssertEqual(status, .active(.toggle))
    }

    // MARK: - Click to Talk

    func testClickUnderHalfSecondToggles() {
        XCTAssertEqual(send(.down(.clickToTalk)), .start(.clickToTalk, mode: nil))
        clock.advance(0.3)
        XCTAssertNil(send(.up(.clickToTalk)))
        clock.advance(4)
        XCTAssertEqual(send(.down(.clickToTalk)), .stop(.clickToTalk))
    }

    func testClickHoldActsAsPushToTalk() {
        machine.pushToTalkSharesToggleKey = true // must not change the mouse threshold
        send(.down(.clickToTalk))
        clock.advance(0.5)
        XCTAssertEqual(send(.up(.clickToTalk)), .stop(.clickToTalk))
    }

    // MARK: - Mode Shortcuts

    func testModeShortcutStartsInItsModeAndToggles() {
        let id = UUID()
        XCTAssertEqual(send(.down(.mode(id))), .start(.modeShortcut, mode: id))
        send(.up(.mode(id)))
        XCTAssertEqual(send(.down(.mode(id))), .stop(.modeShortcut))
    }

    // MARK: - Double Tap

    func testDoubleTapArmsThenFires() {
        machine.options[.pushToTalk] = TriggerOptions(isModifierOnly: true, doubleTap: true)
        XCTAssertNil(send(.down(.pushToTalk)))
        clock.advance(0.1)
        XCTAssertNil(send(.up(.pushToTalk)))
        XCTAssertTrue(machine.isArmed(.pushToTalk))
        clock.advance(0.3)
        XCTAssertEqual(send(.down(.pushToTalk)), .start(.pushToTalk, mode: nil))
        XCTAssertFalse(machine.isArmed(.pushToTalk))
        XCTAssertNil(send(.up(.pushToTalk)), "the firing press does not arm again")

        send(.down(.pushToTalk))
        clock.advance(0.1)
        send(.up(.pushToTalk))
        clock.advance(0.1)
        XCTAssertEqual(send(.down(.pushToTalk)), .stop(.pushToTalk), "a second double tap stops")
    }

    func testDoubleTapWindowExpires() {
        machine.options[.pushToTalk] = TriggerOptions(isModifierOnly: true, doubleTap: true)
        send(.down(.pushToTalk))
        send(.up(.pushToTalk))
        clock.advance(0.41)
        XCTAssertFalse(machine.isArmed(.pushToTalk))
        XCTAssertNil(send(.down(.pushToTalk)), "too late: this press only arms again")
        send(.up(.pushToTalk))
        XCTAssertTrue(machine.isArmed(.pushToTalk))
    }

    func testLongPressOrComboDoesNotArm() {
        machine.options[.pushToTalk] = TriggerOptions(isModifierOnly: true, doubleTap: true)
        send(.down(.pushToTalk))
        clock.advance(0.6)
        send(.up(.pushToTalk))
        XCTAssertFalse(machine.isArmed(.pushToTalk))

        send(.down(.pushToTalk))
        send(.interrupted(.pushToTalk))
        send(.up(.pushToTalk))
        XCTAssertFalse(machine.isArmed(.pushToTalk))
    }

    // MARK: - Mode Switcher Navigation

    func testSwitcherNavigationWrapsAndDigitsMap() {
        XCTAssertEqual(ModeSwitcherNavigation.index(from: 0, moving: -1, count: 3), 2)
        XCTAssertEqual(ModeSwitcherNavigation.index(from: 2, moving: 1, count: 3), 0)
        XCTAssertEqual(ModeSwitcherNavigation.index(from: 1, moving: 1, count: 3), 2)
        XCTAssertEqual(ModeSwitcherNavigation.index(from: nil, moving: 1, count: 3), 0)
        XCTAssertEqual(ModeSwitcherNavigation.index(from: nil, moving: -1, count: 3), 2)
        XCTAssertNil(ModeSwitcherNavigation.index(from: 0, moving: 1, count: 0))
        XCTAssertEqual(ModeSwitcherNavigation.index(forSlot: 0, count: 3), 0)
        XCTAssertNil(ModeSwitcherNavigation.index(forSlot: 9, count: 3), "key 0 picks the tenth mode only")
        XCTAssertEqual(ModeSwitcherNavigation.index(forSlot: 9, count: 10), 9)
    }
}
