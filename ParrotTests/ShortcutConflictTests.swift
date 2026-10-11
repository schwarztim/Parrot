import XCTest

@testable import Parrot

/// "Already in use" refusal, contextual arming, and what gets registered.
final class ShortcutConflictTests: XCTestCase {

    private func defaults() -> [ShortcutName: Shortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutName.allCases.map { ($0, $0.defaultShortcut) })
    }

    private func targets(
        _ shortcuts: [ShortcutName: Shortcut],
        modes: [(id: UUID, shortcut: Shortcut)] = []
    ) -> [ShortcutTarget: Shortcut] {
        ShortcutRegistry.targets(shortcuts: shortcuts, modes: modes)
    }

    // MARK: - Conflicts

    func testComboUsedByAnotherNameIsRefused() {
        let current = targets(defaults())
        XCTAssertEqual(
            ShortcutRegistry.conflict(for: .key(40, [.option, .shift]), assigningTo: .name(.cancelRecording), in: current),
            .name(.changeMode)
        )
        XCTAssertEqual(
            ShortcutRegistry.conflict(for: .key(53), assigningTo: .name(.changeMode), in: current),
            .name(.cancelRecording)
        )
    }

    func testContextualKeysCountAsTaken() {
        let current = targets(defaults())
        XCTAssertEqual(ShortcutRegistry.conflict(for: .key(0x12), assigningTo: .name(.toggleRecording), in: current), .name(.firstMode))
        XCTAssertEqual(ShortcutRegistry.conflict(for: .key(126), assigningTo: .name(.changeMode), in: current), .name(.navigateUp))
    }

    func testPushToTalkAndToggleMayShareAKey() {
        var shortcuts = defaults()
        shortcuts[.toggleRecording] = .key(0x36)
        let current = targets(shortcuts)
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(0x36), assigningTo: .name(.pushToTalk), in: current))
        shortcuts[.pushToTalk] = .key(0x36)
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(0x36), assigningTo: .name(.toggleRecording), in: targets(shortcuts)))
        XCTAssertEqual(
            ShortcutRegistry.conflict(for: .key(0x36), assigningTo: .name(.changeMode), in: targets(shortcuts)),
            .name(.pushToTalk)
        )
    }

    func testOwnBindingAndFreeKeysDoNotConflict() {
        let current = targets(defaults())
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(49, .option), assigningTo: .name(.toggleRecording), in: current))
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(49, [.option, .command]), assigningTo: .name(.toggleRecording), in: current))
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(0x36), assigningTo: .name(.toggleRecording), in: current),
                     "Right Command alone is not Right Option alone")
        XCTAssertNil(ShortcutRegistry.conflict(for: .none, assigningTo: .name(.toggleRecording), in: current))
    }

    func testRemovedBindingsFreeTheirKey() {
        var shortcuts = defaults()
        shortcuts[.changeMode] = Shortcut.none
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(40, [.option, .shift]), assigningTo: .name(.cancelRecording), in: targets(shortcuts)))
    }

    func testMouseButtonsConflictOnAnySharedButton() {
        var shortcuts = defaults()
        shortcuts[.clickToTalk] = Shortcut(keyCode: nil, mouseButtons: [2, 3])
        let current = targets(shortcuts)
        XCTAssertEqual(ShortcutRegistry.conflict(for: .mouse(3), assigningTo: .name(.pushToTalk), in: current), .name(.clickToTalk))
        XCTAssertNil(ShortcutRegistry.conflict(for: .mouse(4), assigningTo: .name(.pushToTalk), in: current))
    }

    func testModeShortcutsConflictBothWays() {
        let email = UUID()
        let notes = UUID()
        let current = targets(defaults(), modes: [(email, .key(0x0E, [.control, .option])), (notes, Shortcut.none)])
        XCTAssertEqual(ShortcutRegistry.conflict(for: .key(0x0E, [.control, .option]), assigningTo: .mode(notes), in: current), .mode(email))
        XCTAssertEqual(ShortcutRegistry.conflict(for: .key(0x0E, [.control, .option]), assigningTo: .name(.changeMode), in: current), .mode(email))
        XCTAssertEqual(ShortcutRegistry.conflict(for: .key(49, .option), assigningTo: .mode(notes), in: current), .name(.toggleRecording))
        XCTAssertNil(ShortcutRegistry.conflict(for: .key(0x0E, [.control, .option]), assigningTo: .mode(email), in: current))
    }

    func testDoubleTapOfATakenKeyStillConflicts() {
        var shortcuts = defaults()
        shortcuts[.pushToTalk] = .key(0x3F)
        XCTAssertEqual(
            ShortcutRegistry.conflict(for: Shortcut(keyCode: 0x3F, doubleTap: true), assigningTo: .name(.changeMode), in: targets(shortcuts)),
            .name(.pushToTalk)
        )
    }

    // MARK: - Arming

    func testCancelIsArmedOnlyWhileRecordingOrSwitcherShown() {
        XCTAssertFalse(ShortcutRegistry.armedNames(isRecording: false, switcherShown: false).contains(.cancelRecording))
        XCTAssertTrue(ShortcutRegistry.armedNames(isRecording: true, switcherShown: false).contains(.cancelRecording))
        XCTAssertTrue(ShortcutRegistry.armedNames(isRecording: false, switcherShown: true).contains(.cancelRecording))
    }

    func testSwitcherKeysAreArmedOnlyWhileShown() {
        let switcherKeys: Set<ShortcutName> = Set(ShortcutName.allCases.filter { $0.scope == .whileSwitcherShown })
        XCTAssertEqual(switcherKeys.count, 13)
        XCTAssertTrue(ShortcutRegistry.armedNames(isRecording: true, switcherShown: false).isDisjoint(with: switcherKeys))
        XCTAssertTrue(switcherKeys.isSubset(of: ShortcutRegistry.armedNames(isRecording: false, switcherShown: true)))
    }

    func testGlobalNamesAreAlwaysArmed() {
        let global: Set<ShortcutName> = [.pushToTalk, .toggleRecording, .clickToTalk, .changeMode]
        XCTAssertEqual(ShortcutRegistry.armedNames(isRecording: false, switcherShown: false), global)
    }

    // MARK: - Plan

    func testIdlePlanRegistersOnlyGlobalBindings() {
        var shortcuts = defaults()
        shortcuts[.clickToTalk] = .mouse(2)
        let plan = ShortcutRegistry.plan(shortcuts: shortcuts, modes: [], isRecording: false, switcherShown: false)
        XCTAssertEqual(Set(plan.bindings.keys), [.name(.pushToTalk), .name(.toggleRecording), .name(.clickToTalk), .name(.changeMode)])
        XCTAssertFalse(plan.pushToTalkSharesToggleKey)
    }

    func testRecordingPlanArmsEscape() {
        let plan = ShortcutRegistry.plan(shortcuts: defaults(), modes: [], isRecording: true, switcherShown: false)
        XCTAssertEqual(plan.bindings[.name(.cancelRecording)], .key(53))
        XCTAssertNil(plan.bindings[.name(.navigateUp)])
    }

    func testSwitcherPlanArmsArrowsReturnAndDigits() {
        let plan = ShortcutRegistry.plan(shortcuts: defaults(), modes: [], isRecording: false, switcherShown: true)
        XCTAssertEqual(plan.bindings.count, 18 - 1, "every name except the unbound mouse shortcut")
        XCTAssertEqual(plan.bindings[.name(.tenthMode)], .key(0x1D))
    }

    func testSharedKeyRegistersPushToTalkOnce() {
        var shortcuts = defaults()
        shortcuts[.pushToTalk] = .key(0x36)
        shortcuts[.toggleRecording] = .key(0x36)
        let plan = ShortcutRegistry.plan(shortcuts: shortcuts, modes: [], isRecording: false, switcherShown: false)
        XCTAssertTrue(plan.pushToTalkSharesToggleKey)
        XCTAssertEqual(plan.bindings[.name(.pushToTalk)], .key(0x36))
        XCTAssertNil(plan.bindings[.name(.toggleRecording)])
    }

    func testModeShortcutsAreRegisteredAndEmptyOnesSkipped() {
        let email = UUID()
        let notes = UUID()
        let plan = ShortcutRegistry.plan(
            shortcuts: defaults(),
            modes: [(email, .key(0x0E, [.control, .option])), (notes, Shortcut.none)],
            isRecording: false,
            switcherShown: false
        )
        XCTAssertEqual(plan.bindings[.mode(email)], .key(0x0E, [.control, .option]))
        XCTAssertNil(plan.bindings[.mode(notes)])
    }

    func testDuplicateInputsRegisterOnlyTheFirst() {
        let email = UUID()
        let plan = ShortcutRegistry.plan(shortcuts: defaults(), modes: [(email, .key(49, .option))], isRecording: false, switcherShown: false)
        XCTAssertEqual(plan.bindings[.name(.toggleRecording)], .key(49, .option))
        XCTAssertNil(plan.bindings[.mode(email)])
    }

    func testRegistrationIDsRoundTrip() {
        let id = UUID()
        for target in [ShortcutTarget.name(.pushToTalk), .name(.tenthMode), .mode(id)] {
            XCTAssertEqual(ShortcutTarget(registrationID: target.registrationID), target)
        }
        XCTAssertNil(ShortcutTarget(registrationID: "mode-nope"))
        XCTAssertNil(ShortcutTarget(registrationID: "unknown"))
    }
}
