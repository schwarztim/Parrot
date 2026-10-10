import CoreGraphics
import XCTest

@testable import Parrot

final class KeyLayoutTests: XCTestCase {

    // MARK: - Paste Key Lookup

    func testQwertyFindsVOnItsOwnKey() {
        let qwerty: [CGKeyCode: Character] = [8: "c", 9: "v", 11: "b", 47: "."]
        XCTAssertEqual(KeyboardLayout.keyCode(for: "v", in: qwerty), 9)
    }

    func testDvorakFindsVOnTheQwertyPeriodKey() {
        // On Dvorak the QWERTY V key types "k" and the QWERTY period key types "v".
        let dvorak: [CGKeyCode: Character] = [8: "j", 9: "k", 11: "x", 47: "v"]
        XCTAssertEqual(KeyboardLayout.keyCode(for: "v", in: dvorak), 47)
    }

    func testAzertyKeepsVInPlace() {
        let azerty: [CGKeyCode: Character] = [0: "q", 6: "w", 9: "v", 12: "a", 13: "z"]
        XCTAssertEqual(KeyboardLayout.keyCode(for: "v", in: azerty), 9)
    }

    func testLookupIgnoresCaseAndPicksLowestCode() {
        XCTAssertEqual(KeyboardLayout.keyCode(for: "v", in: [9: "V"]), 9)
        XCTAssertEqual(KeyboardLayout.keyCode(for: "v", in: [60: "v", 9: "v"]), 9)
    }

    func testLayoutWithoutVGivesNilAndTheFallbackIsAnsiV() {
        let cyrillic: [CGKeyCode: Character] = [8: "с", 9: "м", 11: "и"]
        XCTAssertNil(KeyboardLayout.keyCode(for: "v", in: cyrillic))
        XCTAssertEqual(KeyboardLayout.ansiV, 9)
    }

    // MARK: - US QWERTY Typing Map

    func testLettersAndShift() {
        XCTAssertEqual(USQwerty.key(for: "a"), USQwerty.Key(code: 0, shift: false))
        XCTAssertEqual(USQwerty.key(for: "A"), USQwerty.Key(code: 0, shift: true))
        XCTAssertEqual(USQwerty.key(for: "v"), USQwerty.Key(code: 9, shift: false))
        XCTAssertEqual(USQwerty.key(for: "M"), USQwerty.Key(code: 46, shift: true))
    }

    func testSymbols() {
        XCTAssertEqual(USQwerty.key(for: "!"), USQwerty.Key(code: 18, shift: true))
        XCTAssertEqual(USQwerty.key(for: "?"), USQwerty.Key(code: 44, shift: true))
        XCTAssertEqual(USQwerty.key(for: "/"), USQwerty.Key(code: 44, shift: false))
        XCTAssertEqual(USQwerty.key(for: "\""), USQwerty.Key(code: 39, shift: true))
        XCTAssertEqual(USQwerty.key(for: "~"), USQwerty.Key(code: 50, shift: true))
    }

    func testWhitespaceKeys() {
        XCTAssertEqual(USQwerty.key(for: " "), USQwerty.Key(code: 49, shift: false))
        XCTAssertEqual(USQwerty.key(for: "\t"), USQwerty.Key(code: USQwerty.tabKey, shift: false))
        XCTAssertEqual(USQwerty.key(for: "\n"), USQwerty.Key(code: USQwerty.returnKey, shift: false))
        XCTAssertEqual(USQwerty.key(for: "\r\n"), USQwerty.Key(code: USQwerty.returnKey, shift: false))
    }

    func testEveryPrintableAsciiCharacterHasAKey() {
        for value in UInt8(32)...UInt8(126) {
            let character = Character(UnicodeScalar(value))
            XCTAssertNotNil(USQwerty.key(for: character), "no key for \(character)")
        }
    }

    func testNonAsciiHasNoKey() {
        XCTAssertNil(USQwerty.key(for: "é"))
        XCTAssertNil(USQwerty.key(for: "😀"))
    }
}
