import XCTest
@testable import MossadCore

/// The Bookmarks and Screens pages under Meetings: every bookmark and every kept screen of all meetings.
final class MeetingsSectionsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ id: String, start: TimeInterval, title: String) -> CallRecord {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0.addingTimeInterval(start),
                           end: t0.addingTimeInterval(start + 1800), status: .written)
        r.calendarTitle = title
        return r
    }

    func bookmark(_ offset: TimeInterval, _ note: String? = nil) -> TranscriptMarker {
        TranscriptMarker(offset: offset, text: "★ Bookmarked at 10:00 AM", isBookmark: true, note: note)
    }

    // MARK: Bookmarks

    func testBookmarksAreGroupedByMeetingNewestMeetingFirstAndInTimeOrderInsideOne() {
        var old = record("old", start: 0, title: "Budget review")
        old.markers = [bookmark(300, "Ask about the vendor"), TranscriptMarker(offset: 60, text: "Paused"), bookmark(90)]
        var new = record("new", start: 86_400, title: "Roadmap")
        new.markers = [bookmark(30)]
        let none = record("none", start: 172_800, title: "No marks")

        let groups = BookmarkIndex.groups([old, none, new])
        XCTAssertEqual(groups.map(\.callID), ["new", "old"])
        XCTAssertEqual(groups[1].bookmarks.map(\.offset), [90, 300])
        XCTAssertEqual(groups[1].bookmarks.map(\.note), [nil, "Ask about the vendor"])
        XCTAssertEqual(groups[1].title, "Budget review")
        XCTAssertEqual(groups[1].start, old.start)
        XCTAssertEqual(BookmarkIndex.count(groups), 3)
    }

    func testABlankNoteIsNoNoteAndTheTimeOfDayCountsThePartOfAJoinedMeeting() {
        var r = record("a", start: 0, title: "Sync")
        r.parts = [CallPart(start: t0, end: t0.addingTimeInterval(600), offset: 0),
                   CallPart(start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(4200), offset: 600)]
        r.markers = [bookmark(60, "  \n"), bookmark(700)]
        let marks = BookmarkIndex.groups([r])[0].bookmarks
        XCTAssertNil(marks[0].note)
        XCTAssertEqual(marks[0].time, t0.addingTimeInterval(60))
        XCTAssertEqual(marks[1].time, t0.addingTimeInterval(3700))
    }

    func testABookmarkCarriesTheLineThatWasSaidAtThatMoment() {
        var r = record("a", start: 0, title: "Sync")
        r.utterances = [
            Utterance(track: .them, speakerLabel: "A", start: 10, end: 40, text: "The vendor raised the price."),
            Utterance(track: .me, speakerLabel: "A", start: 41, end: 50, text: "Then we wait."),
        ]
        r.speakerNames = ["them:A": "Sam Carter", "me:A": "Robin Vale"]
        // During a line, that line; a few seconds after the last line, still that line; long after, nothing.
        r.markers = [bookmark(20), bookmark(55), bookmark(400)]
        let said = BookmarkIndex.groups([r])[0].bookmarks.map(\.said)
        XCTAssertEqual(said[0], BookmarkIndex.Said(speaker: "Sam Carter", text: "The vendor raised the price."))
        XCTAssertEqual(said[1], BookmarkIndex.Said(speaker: "Robin Vale", text: "Then we wait."))
        XCTAssertNil(said[2])
    }

    func testTheSearchFindsANoteATitleOrWhatWasSaidWithEveryWordAndNoCaseOrAccent() {
        var a = record("a", start: 0, title: "Café budget")
        a.markers = [bookmark(10, "Ask Jo about the PRICE"), bookmark(20)]
        a.utterances = [Utterance(track: .them, speakerLabel: "A", start: 18, end: 25, text: "We ship in March.")]
        var b = record("b", start: 100, title: "Roadmap")
        b.markers = [bookmark(10, "price list")]

        XCTAssertEqual(BookmarkIndex.groups([a, b], query: "price").map { $0.bookmarks.map(\.offset) }, [[10], [10]])
        XCTAssertEqual(BookmarkIndex.groups([a, b], query: "price jo").map(\.callID), ["a"])
        // A title match keeps every bookmark of that meeting.
        XCTAssertEqual(BookmarkIndex.groups([a, b], query: "cafe").first?.bookmarks.count, 2)
        XCTAssertEqual(BookmarkIndex.groups([a, b], query: "march").first?.bookmarks.map(\.offset), [20])
        XCTAssertEqual(BookmarkIndex.groups([a, b], query: "nothing here"), [])
        XCTAssertEqual(BookmarkIndex.groups([a, b], query: "  ").count, 2)
    }

    // MARK: Screens

    func screen(_ offset: TimeInterval, _ text: String, presenter: String? = nil) -> SharedScreen {
        SharedScreen(offset: offset, file: "\(Int(offset * 1000)).heic", text: text, presenter: presenter)
    }

    func testScreensAreGroupedByMeetingNewestFirstInTimeOrderWithoutDeletedOnes() {
        var old = record("old", start: 0, title: "Budget review")
        old.screens = [screen(300, "Budget table"), screen(120, "Q3 plan")]
        var new = record("new", start: 86_400, title: "Roadmap")
        new.screens = [screen(30, "Roadmap slide"), screen(60, "Gone")]
        new.deletedScreens = ["60000.heic"]
        var empty = record("empty", start: 172_800, title: "No screens")
        empty.screens = []

        let groups = ScreenIndex.groups([old, empty, new])
        XCTAssertEqual(groups.map(\.callID), ["new", "old"])
        XCTAssertEqual(groups[0].screens.map(\.file), ["30000.heic"])
        XCTAssertEqual(groups[1].screens.map(\.offset), [120, 300])
        XCTAssertEqual(groups[1].title, "Budget review")
        XCTAssertEqual(groups[1].times["120000.heic"], old.start.addingTimeInterval(120))
        XCTAssertEqual(ScreenIndex.count(groups), 3)
    }

    func testTheScreenSearchReadsTheRecognizedTextWithTheWordsOfTheScreensTab() {
        var a = record("a", start: 0, title: "Budget review")
        a.screens = [screen(10, "Revenue up 12%\nQ3 plan"), screen(20, "Hiring plan", presenter: "Sam Carter")]
        var b = record("b", start: 100, title: "Roadmap")
        b.screens = [screen(10, "Revenue by region")]

        XCTAssertEqual(ScreenIndex.groups([a, b], query: "revenue").map(\.callID), ["b", "a"])
        XCTAssertEqual(ScreenIndex.groups([a, b], query: "revenue q3").map { $0.screens.map(\.offset) }, [[10]])
        XCTAssertEqual(ScreenIndex.groups([a, b], query: "PLAN").first?.screens.count, 2)
        XCTAssertEqual(ScreenIndex.groups([a, b], query: "sam").first?.screens.map(\.offset), [20])
        // The meeting's title is not the screen's text.
        XCTAssertEqual(ScreenIndex.groups([a, b], query: "budget"), [])
        XCTAssertEqual(ScreenIndex.groups([a, b], query: "").count, 2)
    }
}
