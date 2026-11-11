import XCTest
@testable import MossadCore

final class MeetingOpenRouteTests: XCTestCase {
    func testCalendarModeOpensTheRequestedMeeting() {
        XCTAssertEqual(MeetingOpenRoute.fullPane(calendarMode: true, request: "b", shown: nil), "b")
        XCTAssertEqual(MeetingOpenRoute.fullPane(calendarMode: true, request: "b", shown: "a"), "b")
    }

    func testNoRequestKeepsWhatIsShown() {
        XCTAssertEqual(MeetingOpenRoute.fullPane(calendarMode: true, request: nil, shown: "a"), "a")
        XCTAssertNil(MeetingOpenRoute.fullPane(calendarMode: true, request: nil, shown: nil))
    }

    func testSplitModeHasNoFullPane() {
        XCTAssertNil(MeetingOpenRoute.fullPane(calendarMode: false, request: "b", shown: nil))
    }

    func testASeekStaysOnlyForTheMeetingThatOpens() {
        XCTAssertTrue(MeetingOpenRoute.keepsSeek(for: "a", opening: "a"))
        XCTAssertFalse(MeetingOpenRoute.keepsSeek(for: "a", opening: "b"))
        XCTAssertFalse(MeetingOpenRoute.keepsSeek(for: nil, opening: "b"))
    }
}
