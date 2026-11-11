import XCTest
@testable import MossadCore

/// Whether the owner shares the screen, from the call apps' own share bars. Unknown is not false.
final class OwnerShareTests: XCTestCase {
    func testTheShareBarsOfTheCallAppsSayTheOwnerShares() {
        XCTAssertEqual(OwnerShare.isSharing([("zoom.us", "zoom share toolbar window")]), true)
        XCTAssertEqual(OwnerShare.isSharing([("Microsoft Teams", "Sharing control bar | Microsoft Teams")]), true)
        XCTAssertEqual(OwnerShare.isSharing([("Google Chrome", "meet.google.com is sharing your screen.")]), true)
        XCTAssertEqual(OwnerShare.isSharing([("Safari", "Sharing this tab")]), true)
    }

    func testOtherWindowsSayNoAndWindowsWithNoTitleSayNothing() {
        XCTAssertEqual(OwnerShare.isSharing([("zoom.us", "Zoom Meeting"), ("Finder", "Documents")]), false)
        XCTAssertNil(OwnerShare.isSharing([("zoom.us", nil), ("Google Chrome", nil)]), "no titles: no permission")
        XCTAssertNil(OwnerShare.isSharing([]))
        XCTAssertEqual(OwnerShare.isSharing([("Notes", "My notes about sharing your screen")]), false, "only a call app's or browser's bar")
    }
}
