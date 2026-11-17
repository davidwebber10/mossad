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

    /// Calendar mode keeps a request only for the live call whose record has not arrived yet. A request for any other
    /// id in no list (a link to a deleted meeting) is taken at once, so it never acts later, far from the click.
    func testOnlyTheLiveCallWaitsForItsRecord() {
        XCTAssertTrue(MeetingOpenRoute.waits(calendarMode: true, request: "live", known: false, liveID: "live"))
        XCTAssertFalse(MeetingOpenRoute.waits(calendarMode: true, request: "gone", known: false, liveID: "live"))
        XCTAssertFalse(MeetingOpenRoute.waits(calendarMode: true, request: "gone", known: false, liveID: nil))
        XCTAssertFalse(MeetingOpenRoute.waits(calendarMode: true, request: "live", known: true, liveID: "live"), "known: it opens")
        XCTAssertFalse(MeetingOpenRoute.waits(calendarMode: false, request: "live", known: false, liveID: "live"),
                       "List mode keeps the selection and needs no request")
    }
}
