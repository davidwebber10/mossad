import XCTest
@testable import MossadCore

final class NowCardTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(title: String? = nil) -> CallRecord {
        var r = CallRecord(id: "2027-01-15-0900", platform: .meet, bundleID: "com.google.Chrome", start: start, end: start, status: .recording)
        r.customTitle = title
        return r
    }

    func testTitle() {
        XCTAssertEqual(NowCard.title(record(title: "Budget review")), "Budget review")
        XCTAssertEqual(NowCard.title(record()), "Current call", "a call with only the platform's name")
        XCTAssertEqual(NowCard.title(nil), "Current call", "a recording whose record is not read yet")
    }

    /// The card is selected only while its page shows: in List mode the live call is the selection, in Calendar mode
    /// it is the meeting open full-pane.
    func testSelected() {
        let id = "live"
        XCTAssertTrue(NowCard.isShown(liveID: id, onMeetings: true, calendarMode: false, selected: id, openedFullPane: nil))
        XCTAssertFalse(NowCard.isShown(liveID: id, onMeetings: true, calendarMode: false, selected: "other", openedFullPane: nil))
        XCTAssertFalse(NowCard.isShown(liveID: id, onMeetings: false, calendarMode: false, selected: id, openedFullPane: nil),
                       "another page shows")
        XCTAssertTrue(NowCard.isShown(liveID: id, onMeetings: true, calendarMode: true, selected: "other", openedFullPane: id))
        XCTAssertFalse(NowCard.isShown(liveID: id, onMeetings: true, calendarMode: true, selected: id, openedFullPane: nil),
                       "the calendar shows, though the live call was the last one opened")
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(NowCard.accessibilityLabel(title: "Budget review", seconds: 12 * 60 + 40, paused: false, mute: .none),
                       "Recording now: Budget review, 12 minutes")
        XCTAssertEqual(NowCard.accessibilityLabel(title: "Budget review", seconds: 50, paused: false, mute: .muted),
                       "Recording now: Budget review, less than a minute, muted")
        XCTAssertEqual(NowCard.accessibilityLabel(title: "Budget review", seconds: 61, paused: false, mute: .mutedWhenLastSeen),
                       "Recording now: Budget review, 1 minute, muted when last seen")
        XCTAssertEqual(NowCard.accessibilityLabel(title: "Budget review", seconds: 3 * 3600 + 120, paused: true, mute: .muted),
                       "Recording now: Budget review, 182 minutes, paused")
    }

    /// One state line, one height: the note takes the place of "Recording", and "Muted when last seen" has no time,
    /// so it fits the sidebar without a second line.
    func testStateLine() {
        XCTAssertEqual(NowCard.stateLine(elapsed: "12:08", paused: false, mute: .none), "Recording 12:08")
        XCTAssertEqual(NowCard.stateLine(elapsed: "12:08", paused: false, mute: .muted), "Muted · 12:08")
        XCTAssertEqual(NowCard.stateLine(elapsed: "12:08", paused: false, mute: .mutedWhenLastSeen), "Muted when last seen")
        XCTAssertEqual(NowCard.stateLine(elapsed: "12:08", paused: true, mute: .none), "Paused · 12:08")
        XCTAssertEqual(NowCard.stateLine(elapsed: "1:02:08", paused: true, mute: .mutedWhenLastSeen), "Paused · 1:02:08",
                       "paused says the most: nothing records")
    }
}
