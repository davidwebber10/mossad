import XCTest
@testable import MossadCore

/// The release check of 2.23: the seams between the list window, the live points, and Recurring.
final class ReleaseSeamTests: XCTestCase {
    // M2: a far invite opened from a search or a link stays when the search closes.
    func testTheListKeepsASelectionItKnowsWhenTheSearchCloses() {
        // In the list: kept.
        XCTAssertTrue(MeetingListRows.keepsSelection("m1", query: "", inList: true, known: true))
        // An invite past the two work days, with no search: kept, shown without a row.
        XCTAssertTrue(MeetingListRows.keepsSelection("upcoming:far", query: "", inList: false, known: true))
        // Return or Down Arrow from a search with text: the first row of what it found.
        XCTAssertFalse(MeetingListRows.keepsSelection("upcoming:far", query: "budget", inList: false, known: true))
        // A selection that is gone, or none.
        XCTAssertFalse(MeetingListRows.keepsSelection("gone", query: "", inList: false, known: false))
        XCTAssertFalse(MeetingListRows.keepsSelection(nil, query: "", inList: false, known: false))
    }

    // L1: a change during a call waits for the sync after the call.
    func testAChangeOfThePointsDuringACallDoesNotSync() {
        XCTAssertFalse(LivePointRules.syncsAfterChange(recording: true))
        XCTAssertTrue(LivePointRules.syncsAfterChange(recording: false))
    }

    // L2: a call that Mossad did not keep holds no "done".
    func testACallThatWasNotKeptReopensItsTicks() {
        let s = MeetingSeries(id: "s", keys: ["s"], title: "TB", meetings: [], upcoming: [], cadence: nil, recurringInCalendar: true, usualPeople: [])
        var book = NextTimeBook()
        let ticked = book.add("Pricing", series: s)!
        let other = book.add("Hiring", series: s)!
        let elsewhere = book.add("Budget", series: s)!
        book.update(ticked.id) { $0.done = .init(callID: "skipped", at: 120, quote: nil, date: Date(), byOwner: true) }
        book.update(elsewhere.id) { $0.done = .init(callID: "kept", at: 60, quote: nil, date: Date(), byOwner: true) }
        XCTAssertTrue(book.reopen(doneIn: "skipped"))
        XCTAssertTrue(book.points.first { $0.id == ticked.id }!.isOpen)
        XCTAssertTrue(book.points.first { $0.id == other.id }!.isOpen)
        XCTAssertFalse(book.points.first { $0.id == elsewhere.id }!.isOpen)
        XCTAssertFalse(book.reopen(doneIn: "skipped"), "nothing left to reopen: no save")
    }

    // L4: the Stats tab's "Skipped" line uses the band's words.
    func testTheSkippedLineReadsTheSchedule() {
        let s = SeriesSchedule(weekdays: [5], minuteOfDay: 900, rhythm: .weekly)
        XCTAssertEqual(s.skippedText(gaps: 0), "Mossad recorded every meeting (every Thursday 15:00) since the first.")
        XCTAssertEqual(s.skippedText(gaps: 2),
                       "2 times with no meeting recorded (every Thursday 15:00). Mossad cannot tell a cancelled meeting from one it did not record.")
        XCTAssertEqual(s.skippedText(gaps: 1)?.hasPrefix("1 time with no meeting recorded"), true)
        XCTAssertNil(SeriesSchedule.none.skippedText(gaps: 1))
        // F8: a series that ended has no words for a skipped meeting.
        XCTAssertNil(SeriesSchedule(weekdays: [], times: [:], minuteOfDay: nil, rhythm: .weekly, ended: true).skippedText(gaps: 2))
    }
}
