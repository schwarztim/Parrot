import AppKit
import XCTest

@testable import Parrot

/// The named shortcuts, their storage, the Superwhisper decoder and the
/// migration from the single pre-registry binding.
final class ShortcutRegistryTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ParrotShortcutRegistryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(store: SettingsStore(defaults: defaults), secrets: InMemorySecretStore())
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: - Names and Defaults

    func testAllEighteenNamesInSpecOrder() {
        XCTAssertEqual(ShortcutName.allCases.map(\.rawValue), [
            "pushToTalk", "toggleRecording", "clickToTalk", "changeMode", "cancelRecording",
            "navigateUp", "navigateDown", "actionSubmit",
            "firstMode", "secondMode", "thirdMode", "fourthMode", "fifthMode",
            "sixthMode", "seventhMode", "eighthMode", "ninthMode", "tenthMode",
        ])
        XCTAssertEqual(Set(ShortcutName.configurable), Set(ShortcutName.allCases.filter(\.isConfigurable)))
        XCTAssertEqual(ShortcutName.configurable.count, 5)
    }

    func testSpecDefaults() {
        XCTAssertEqual(ShortcutName.pushToTalk.defaultShortcut, .key(0x3D))
        XCTAssertEqual(ShortcutName.toggleRecording.defaultShortcut, Shortcut(keyCode: 49, modifiers: .option))
        XCTAssertEqual(ShortcutName.changeMode.defaultShortcut, Shortcut(keyCode: 40, modifiers: [.option, .shift]))
        XCTAssertEqual(ShortcutName.cancelRecording.defaultShortcut, .key(53))
        XCTAssertTrue(ShortcutName.clickToTalk.defaultShortcut.isEmpty)
        XCTAssertEqual(ShortcutName.navigateUp.defaultShortcut, .key(126))
        XCTAssertEqual(ShortcutName.navigateDown.defaultShortcut, .key(125))
        XCTAssertEqual(ShortcutName.actionSubmit.defaultShortcut, .key(36))
        let digitKeys = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        let slots = ShortcutName.allCases.compactMap { name in name.modeSlot.map { (name, $0) } }
        XCTAssertEqual(slots.count, 10)
        for (name, slot) in slots {
            XCTAssertEqual(name.defaultShortcut, .key(digitKeys[slot]), "\(name)")
            XCTAssertEqual(name.defaultShortcut.keycaps, ["\((slot + 1) % 10)"])
        }
    }

    // MARK: - Shortcut Value

    func testLoneModifierDropsItsModifierBits() {
        let rightCommand = Shortcut(keyCode: 0x36, modifiers: [.command, .shift])
        XCTAssertEqual(rightCommand, .key(0x36))
        XCTAssertTrue(rightCommand.isModifierOnly)
        XCTAssertEqual(rightCommand.modifiers, 0)
    }

    func testMouseBindingHasNoKey() {
        let mouse = Shortcut(keyCode: 12, modifiers: .command, mouseButtons: [3, 2, 3])
        XCTAssertNil(mouse.keyCode)
        XCTAssertEqual(mouse.modifiers, 0)
        XCTAssertEqual(mouse.mouseButtons, [2, 3])
    }

    func testJSONRoundTripIncludesMouseButtonsAndDoubleTap() throws {
        let values: [Shortcut] = [
            .key(49, .option),
            .mouse(2),
            Shortcut(keyCode: nil, mouseButtons: [3, 4]),
            Shortcut(keyCode: Shortcut.functionKeyCode, doubleTap: true),
            .none,
        ]
        for value in values {
            let data = try encoded(value)
            XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), value)
        }
        let json = String(decoding: try encoded(Shortcut.mouse(2)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"mouseButtons\":[2]"), json)
    }

    func testKeycapsAndDisplayNames() {
        XCTAssertEqual(Shortcut.key(49, .option).keycaps, ["⌥", "Space"])
        XCTAssertEqual(Shortcut.key(49, .option).displayName, "⌥Space")
        XCTAssertEqual(Shortcut.key(40, [.command, .shift, .option, .control]).keycaps, ["⌃", "⌥", "⇧", "⌘", "K"])
        XCTAssertEqual(Shortcut.key(0x36).keycaps, ["Right ⌘"])
        XCTAssertEqual(Shortcut.key(0x36).displayName, "Right Command")
        XCTAssertEqual(Shortcut.key(0x3F).keycaps, ["fn"])
        XCTAssertEqual(Shortcut(keyCode: 0x3F, doubleTap: true).displayName, "Double-tap Fn")
        XCTAssertEqual(Shortcut.key(0x39).displayName, "Caps Lock")
        XCTAssertEqual(Shortcut.mouse(2).keycaps, ["Scroll Wheel Click"])
        XCTAssertEqual(Shortcut.mouse(3).displayName, "Mouse Button 4")
        XCTAssertEqual(Shortcut.none.keycaps, [])
        XCTAssertEqual(Shortcut.none.displayName, "None")
    }

    func testLegacyAndModeConversions() {
        let legacy = HotkeyBinding(keyCode: 0x31, modifiers: [.command, .shift], displayName: "x")
        XCTAssertEqual(Shortcut(legacy: legacy), .key(0x31, [.command, .shift]))
        XCTAssertEqual(Shortcut(legacy: .defaultHotkey), .key(0x3D))
        XCTAssertEqual(Shortcut(legacy: HotkeyBinding(keyCode: 0, modifiers: [], displayName: "M", mouseButton: 3)), .mouse(3))
        XCTAssertNil(Shortcut(legacy: .empty), "keyCode 0 without a mouse button was never a working binding")

        XCTAssertEqual(Shortcut.key(0x36).legacyBinding?.keyCode, 0x36)
        XCTAssertEqual(Shortcut.key(0x36).legacyBinding?.displayName, "Right Command")
        XCTAssertNil(Shortcut.none.legacyBinding)

        let mode = ModeShortcut(keyCode: 0x0E, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)
        XCTAssertEqual(Shortcut(mode: mode), .key(0x0E, [.control, .option]))
        XCTAssertEqual(Shortcut(mode: mode).modeShortcut, mode)
        XCTAssertEqual(Shortcut.mouse(4).modeShortcut, ModeShortcut(keyCode: 0, modifiers: 0, mouseButton: 4))
        XCTAssertEqual(Shortcut(mode: ModeShortcut(keyCode: 0, mouseButton: 4)), .mouse(4))
    }

    // MARK: - Superwhisper Decoder

    func testSuperwhisperOperatorBindingsDecodeToLoneModifiers() {
        let ptt = SuperwhisperShortcut.shortcut(fromJSON: #"{"carbonKeyCode":54,"carbonModifiers":256,"mouseButtonNumbers":[]}"#)
        XCTAssertEqual(ptt, .key(54))
        XCTAssertEqual(ptt?.displayName, "Right Command")
        XCTAssertEqual(ptt?.legacyBinding?.modifiers, [])

        let toggle = SuperwhisperShortcut.shortcut(fromJSON: #"{"carbonKeyCode":62,"carbonModifiers":4096,"mouseButtonNumbers":[]}"#)
        XCTAssertEqual(toggle, .key(62))
        XCTAssertEqual(toggle?.displayName, "Right Control")
    }

    func testSuperwhisperCombosMouseAndModifierMap() {
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 49, carbonModifiers: 2048), .key(49, .option))
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 40, carbonModifiers: 2560), .key(40, [.option, .shift]))
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 0, carbonModifiers: 256), .key(0, .command), "Cmd+A is key code 0")
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 61, carbonModifiers: 2048), .key(61), "Right Option alone")
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 63, carbonModifiers: 0), .key(63), "Fn alone")
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 57, carbonModifiers: 1024), .key(57), "Caps Lock alone")
        XCTAssertEqual(SuperwhisperShortcut.shortcut(fromJSON: #"{"carbonKeyCode":0,"carbonModifiers":0,"mouseButtonNumbers":[2]}"#), .mouse(2))
        XCTAssertEqual(SuperwhisperShortcut.shortcut(carbonKeyCode: 0, carbonModifiers: 0), Shortcut.none)

        XCTAssertEqual(SuperwhisperShortcut.modifierFlags(carbon: 256 | 512 | 1024 | 2048 | 4096),
                       [.command, .shift, .capsLock, .option, .control])
        XCTAssertEqual(SuperwhisperShortcut.modifierFlags(carbon: 8192 | 16384 | 32768), [.shift, .option, .control])
        XCTAssertEqual(SuperwhisperShortcut.carbonModifiers([.option, .shift]), 2560)
    }

    func testSuperwhisperDefaultsValuesAndKeys() {
        XCTAssertEqual(SuperwhisperShortcut.shortcut(fromDefaultsValue: #"{"carbonKeyCode":53,"carbonModifiers":0,"mouseButtonNumbers":[]}"#), .key(53))
        XCTAssertEqual(SuperwhisperShortcut.shortcut(fromDefaultsValue: Data(#"{"carbonKeyCode":49,"carbonModifiers":2048}"#.utf8)), .key(49, .option))
        XCTAssertEqual(SuperwhisperShortcut.shortcut(fromDefaultsValue: false), Shortcut.none)
        XCTAssertNil(SuperwhisperShortcut.shortcut(fromDefaultsValue: 42))
        XCTAssertNil(SuperwhisperShortcut.shortcut(fromJSON: "not json"))

        XCTAssertEqual(SuperwhisperShortcut.shortcutName(forDefaultsKey: "KeyboardShortcuts_pushToTalk"), .pushToTalk)
        XCTAssertEqual(SuperwhisperShortcut.shortcutName(forDefaultsKey: "KeyboardShortcuts_tenthMode"), .tenthMode)
        XCTAssertNil(SuperwhisperShortcut.shortcutName(forDefaultsKey: "KeyboardShortcuts_unknown"))
        XCTAssertNil(SuperwhisperShortcut.shortcutName(forDefaultsKey: "pushToTalk"))
    }

    func testSuperwhisperModeShortcut() throws {
        let data = Data(#"{"carbonKeyCode":14,"carbonModifiers":6144}"#.utf8)
        let expected = ModeShortcut(keyCode: 14, modifiers: NSEvent.ModifierFlags([.option, .control]).rawValue)
        XCTAssertEqual(SuperwhisperShortcut.modeShortcut(fromJSON: data), expected)
        XCTAssertEqual(SuperwhisperShortcut.modeShortcut(carbonKeyCode: 14, carbonModifiers: 6144), expected)

        struct ImportedMode: Decodable { let shortcut: SuperwhisperShortcut.Payload? }
        let mode = try JSONDecoder().decode(ImportedMode.self, from: Data(#"{"shortcut":{"carbonKeyCode":14,"carbonModifiers":6144}}"#.utf8))
        XCTAssertEqual(mode.shortcut?.modeShortcut, expected)
    }

    // MARK: - Storage

    func testDefaultsOnFreshSuiteWriteNothing() {
        let settings = makeSettings()
        for name in ShortcutName.allCases {
            XCTAssertEqual(settings.hotkeys.shortcut(for: name), name.defaultShortcut, "\(name)")
        }
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?.keys.first { $0.hasPrefix("parrot.hotkeys") })
    }

    func testSetResetAndRemoveRoundTrip() {
        let settings = makeSettings()
        settings.hotkeys.setShortcut(.mouse(2), for: .clickToTalk)
        settings.hotkeys.setShortcut(.none, for: .changeMode)
        settings.hotkeys.setShortcut(.key(0x36), for: .toggleRecording)

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .clickToTalk), .mouse(2))
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .changeMode), Shortcut.none)
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .toggleRecording), .key(0x36))
        XCTAssertNotNil(defaults.data(forKey: "parrot.hotkeys.clickToTalk"))

        reloaded.hotkeys.resetShortcut(.changeMode)
        XCTAssertNil(defaults.object(forKey: "parrot.hotkeys.changeMode"))
        XCTAssertTrue(reloaded.hotkeys.isDefault(.changeMode))
        XCTAssertEqual(makeSettings().hotkeys.shortcut(for: .changeMode), ShortcutName.changeMode.defaultShortcut)
    }

    func testPushToTalkMirrorsTheLegacyBindingBothWays() {
        let settings = makeSettings()
        settings.hotkeys.setShortcut(.key(0x36), for: .pushToTalk)
        XCTAssertEqual(settings.hotkeys.hotkeyBinding.keyCode, 0x36)
        XCTAssertEqual(settings.hotkeys.hotkeyBinding.displayName, "Right Command")

        settings.hotkeys.hotkeyBinding = HotkeyBinding(keyCode: 0x31, modifiers: [.control], displayName: "⌃Space")
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), .key(0x31, .control))

        settings.hotkeys.setShortcut(Shortcut(keyCode: 0x3F, doubleTap: true), for: .pushToTalk)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), Shortcut(keyCode: 0x3F, doubleTap: true),
                       "the mirror must not drop double-tap")

        settings.hotkeys.setShortcut(.none, for: .pushToTalk)
        XCTAssertEqual(settings.hotkeys.hotkeyBinding, .empty)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), Shortcut.none)
    }

    // MARK: - Migration

    func testFreshInstallKeepsSpecDefaults() {
        let settings = makeSettings()
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: false)

        XCTAssertTrue(settings.hotkeys.migrated)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), .key(0x3D), "Parrot's Right Option push to talk")
        XCTAssertEqual(settings.hotkeys.shortcut(for: .toggleRecording), .key(49, .option))
        XCTAssertEqual(settings.hotkeys.shortcut(for: .changeMode), .key(40, [.option, .shift]))
        XCTAssertEqual(settings.hotkeys.shortcut(for: .cancelRecording), .key(53))
        XCTAssertTrue(makeSettings().hotkeys.migrated)
    }

    func testExistingInstallKeepsItsPushToTalkAndCancelKeys() throws {
        let legacy = HotkeyBinding(keyCode: 0x36, modifiers: [], displayName: "Right Command")
        let cancel = HotkeyBinding(keyCode: 0x32, modifiers: [.control], displayName: "⌃`")
        defaults.set(try encoded(legacy), forKey: "parrot.hotkeyBinding")
        defaults.set(try encoded(cancel), forKey: "parrot.cancelHotkeyBinding")

        let settings = makeSettings()
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), .key(0x36), "read before migration")
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: true)

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .pushToTalk), .key(0x36))
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .cancelRecording), .key(0x32, .control))
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .toggleRecording), Shortcut.none)
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .changeMode), Shortcut.none)
        XCTAssertEqual(reloaded.hotkeys.shortcut(for: .navigateUp), .key(126), "contextual keys keep defaults")
        XCTAssertEqual(reloaded.hotkeys.hotkeyBinding, legacy, "old key is not rewritten")
    }

    func testExistingInstallWithDefaultKeyKeepsRightOption() {
        let settings = makeSettings()
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: true)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), .key(0x3D))
        XCTAssertEqual(settings.hotkeys.shortcut(for: .cancelRecording), .key(53))
        XCTAssertEqual(settings.hotkeys.shortcut(for: .toggleRecording), Shortcut.none)
    }

    func testBrokenLegacyBindingMigratesToRightOption() throws {
        defaults.set(try encoded(HotkeyBinding.empty), forKey: "parrot.hotkeyBinding")
        let settings = makeSettings()
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: true)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), .key(0x3D), "the listener used Right Option for it")
    }

    func testLegacyMouseBindingMigrates() throws {
        let mouse = HotkeyBinding(keyCode: 0, modifiers: [], displayName: "Mouse Button 4", mouseButton: 3)
        defaults.set(try encoded(mouse), forKey: "parrot.hotkeyBinding")
        let settings = makeSettings()
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: false)
        XCTAssertEqual(settings.hotkeys.shortcut(for: .pushToTalk), .mouse(3))
    }

    func testMigrationRunsOnceAndKeepsLaterChoices() {
        let settings = makeSettings()
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: true)
        settings.hotkeys.setShortcut(.key(49, .option), for: .toggleRecording)
        settings.hotkeys.migrateIfNeeded(hasCompletedOnboarding: true)
        XCTAssertEqual(makeSettings().hotkeys.shortcut(for: .toggleRecording), .key(49, .option))
    }
}
