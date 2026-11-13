import XCTest
@testable import MossadCore

/// A system-wide shortcut as Settings records it: its saved form, its symbols and spoken words, and the
/// combinations it may not take.
final class HotKeyShortcutTests: XCTestCase {
    func testTheDefaultIsOptionCommandM() {
        let s = HotKeyShortcut.askDefault
        XCTAssertEqual(s.symbols, "⌥⌘M")
        XCTAssertEqual(s.spoken, "Option-Command-M")
    }

    func testTheSavedFormComesBack() {
        let s = HotKeyShortcut(keyCode: 0x2E, modifiers: [.option, .command])
        XCTAssertEqual(HotKeyShortcut(saved: s.saved), s)
        let t = HotKeyShortcut(keyCode: 0x31, modifiers: [.control, .shift])
        XCTAssertEqual(HotKeyShortcut(saved: t.saved), t)
        XCTAssertEqual(t.symbols, "⌃⇧Space")
    }

    func testABrokenSavedFormIsNoShortcut() {
        XCTAssertNil(HotKeyShortcut(saved: ""))
        XCTAssertNil(HotKeyShortcut(saved: "cmd"))
        XCTAssertNil(HotKeyShortcut(saved: "999:x"))
    }

    func testTheSymbolsAreInTheMacOrder() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x00, modifiers: [.command, .shift, .option, .control]).symbols, "⌃⌥⇧⌘A")
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x7A, modifiers: [.command]).symbols, "⌘F1")
    }

    func testAKeyAloneOrWithShiftIsRefused() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x2E, modifiers: []).problem, .needsModifier)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x2E, modifiers: [.shift]).problem, .needsModifier)
        XCTAssertNil(HotKeyShortcut(keyCode: 0x2E, modifiers: [.control, .option]).problem)
    }

    func testTheBookmarkShortcutIsTaken() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x0B, modifiers: [.control, .option]).problem, .bookmark)
    }

    func testTheSystemsAndMossadsOwnAreTaken() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x31, modifiers: [.command]).problem, .system)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x0C, modifiers: [.command]).problem, .system)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x28, modifiers: [.option, .command]).problem, .mossad)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x28, modifiers: [.command]).problem, .mossad)
    }

    func testAKeyWithNoNameIsRefused() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x3F, modifiers: [.command, .option]).problem, .unknownKey)
    }

    func testEachProblemSaysWhatToDo() {
        for p in [HotKeyShortcut.Problem.needsModifier, .bookmark, .system, .mossad, .unknownKey, .taken, .typesCharacter] {
            XCTAssertFalse(p.message.isEmpty)
        }
        XCTAssertEqual(HotKeyShortcut.Problem.taken.message, "macOS did not accept this shortcut, so it does not work now. Choose another.")
    }

    func testOptionOrControlAloneWithACharacterTypesInEveryApp() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x0E, modifiers: [.option]).problem, .typesCharacter)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x0E, modifiers: [.option, .shift]).problem, .typesCharacter)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x0E, modifiers: [.control]).problem, .typesCharacter)
        XCTAssertNil(HotKeyShortcut(keyCode: 0x7A, modifiers: [.option]).problem)
        XCTAssertNil(HotKeyShortcut(keyCode: 0x0E, modifiers: [.control, .option]).problem)
    }

    func testTheMeetingsFilterKeysAndMoreSystemKeysAreTaken() {
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x03, modifiers: [.option, .command]).problem, .mossad)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x33, modifiers: [.option, .command]).problem, .mossad)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x7B, modifiers: [.control]).problem, .system)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x02, modifiers: [.option, .command]).problem, .system)
        XCTAssertEqual(HotKeyShortcut(keyCode: 0x1C, modifiers: [.option, .command]).problem, .system)
    }
}
