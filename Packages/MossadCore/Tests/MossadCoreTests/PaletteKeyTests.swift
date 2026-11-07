import XCTest
@testable import MossadCore

final class PaletteKeyTests: XCTestCase {
    func key(_ code: UInt16, shift: Bool = false, command: Bool = false, option: Bool = false, control: Bool = false,
             composing: Bool = false) -> PaletteKey? {
        PaletteKey(keyCode: code, shift: shift, command: command, option: option, control: control, composing: composing)
    }

    func testTheKeysThePaletteTakes() {
        XCTAssertEqual(key(125), .move(1))
        XCTAssertEqual(key(126), .move(-1))
        XCTAssertEqual(key(48), .nextGroup(backward: false))
        XCTAssertEqual(key(48, shift: true), .nextGroup(backward: true))
        XCTAssertEqual(key(36), .open(transcript: false))
        XCTAssertEqual(key(76), .open(transcript: false), "The keypad's Enter")
        XCTAssertEqual(key(36, command: true), .open(transcript: true))
        XCTAssertEqual(key(53), .close)
    }

    func testOtherKeysGoToTheField() {
        XCTAssertNil(key(0), "Letters")
        XCTAssertNil(key(51), "Delete")
        XCTAssertNil(key(123), "Left arrow moves the caret")
        XCTAssertNil(key(125, command: true), "Command-Down moves the caret")
        XCTAssertNil(key(125, option: true))
        XCTAssertNil(key(48, control: true), "Control-Tab is the system's")
        XCTAssertNil(key(36, option: true))
    }

    func testAWordBeingComposedKeepsItsKeys() {
        for code: UInt16 in [125, 126, 48, 36, 76, 53] { XCTAssertNil(key(code, composing: true)) }
    }
}
