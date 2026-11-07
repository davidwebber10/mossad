import XCTest
@testable import MossadCore

final class WindowLayoutTests: XCTestCase {
    private func width(_ saved: Double, window: Double) -> Double {
        ColumnWidth.list(saved: saved, range: 252...472, window: window, sidebar: 210, detailMin: 538)
    }

    func testKeepsTheSavedWidthWhenThereIsRoom() {
        XCTAssertEqual(width(312, window: 1240), 312)
        XCTAssertEqual(width(472, window: 1400), 472)
    }

    func testClampsToTheFixedRange() {
        XCTAssertEqual(width(100, window: 1400), 252)
        XCTAssertEqual(width(900, window: 2000), 472)
    }

    func testANarrowWindowCapsTheListSoTheDetailKeepsItsMinimum() {
        XCTAssertEqual(width(472, window: 1060), 312)
        XCTAssertEqual(width(472, window: 1100), 352)
        XCTAssertEqual(width(300, window: 1060), 300)
    }

    func testNeverGoesBelowTheMinimumEvenInATinyWindow() {
        XCTAssertEqual(width(472, window: 900), 252)
        XCTAssertEqual(width(312, window: 0), 252)
    }

    func testANonFiniteValueFallsBackToTheMinimum() {
        XCTAssertEqual(width(.nan, window: 1400), 252)
    }

    func testDoubleClickFollowsTheSystemSetting() {
        XCTAssertEqual(DoubleClickAction(defaultsValue: "Maximize"), .zoom)
        XCTAssertEqual(DoubleClickAction(defaultsValue: "Fill"), .fill)
        XCTAssertEqual(DoubleClickAction(defaultsValue: "Minimize"), .minimize)
        XCTAssertEqual(DoubleClickAction(defaultsValue: "None"), .none)
        // Unset means the system default, which is Fill since macOS 15.
        XCTAssertEqual(DoubleClickAction(defaultsValue: nil), .fill)
        XCTAssertEqual(DoubleClickAction(defaultsValue: "Something new"), .fill)
    }
}

final class TypeSelectTests: XCTestCase {
    private let names = ["Meetings", "Commitments", "Chat", "People", "Analytics", "Settings", "Log"]

    func testJumpsToTheFirstNameWithTheLetter() {
        XCTAssertEqual(TypeSelect.next(in: names, typed: "p", after: 0), 3)
        XCTAssertEqual(TypeSelect.next(in: names, typed: "L", after: 0), 6)
    }

    func testTheSameLetterAgainMovesToTheNextMatchAndWraps() {
        XCTAssertEqual(TypeSelect.next(in: names, typed: "c", after: 0), 1)
        XCTAssertEqual(TypeSelect.next(in: names, typed: "c", after: 1), 2)
        XCTAssertEqual(TypeSelect.next(in: names, typed: "c", after: 2), 1)
        XCTAssertEqual(TypeSelect.next(in: names, typed: "m", after: 0), 0)
    }

    func testNoMatchGivesNil() {
        XCTAssertNil(TypeSelect.next(in: names, typed: "z", after: 0))
        XCTAssertNil(TypeSelect.next(in: names, typed: "", after: 0))
        XCTAssertEqual(TypeSelect.next(in: names, typed: "a", after: nil), 4)
    }
}
