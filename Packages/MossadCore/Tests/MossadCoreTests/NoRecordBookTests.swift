import XCTest
@testable import MossadCore

final class NoRecordBookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let meet = "https://meet.google.com/abc-defg-hij"
    private let week: Double = 60 * 24 * 7

    private func event(_ title: String, in minutes: Double, length: Double = 30, text: String) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                          attendees: [], text: text, isAllDay: false)
    }

    private func meeting(_ e: CalendarEventInfo) -> UpcomingMeeting {
        UpcomingMeeting.from([e], now: now.addingTimeInterval(-86_400 * 2), days: 30)[0]
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testAMeetingIsRecordedUntilTheOwnerSaysOtherwise() {
        let e = event("Alex / Sam", in: 0, text: meet)
        let book = NoRecordBook()
        XCTAssertEqual(book.choice(for: meeting(e)), .record)
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0), events: [e]))
    }

    func testThisMeetingBlocksOnlyThatOccurrence() {
        let friday = event("Alex / Sam", in: 0, text: meet)
        let nextFriday = event("Alex / Sam", in: week, text: meet)
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(friday))
        XCTAssertEqual(book.choice(for: meeting(friday)), .skipThisMeeting)
        XCTAssertEqual(book.choice(for: meeting(nextFriday)), .record)
        XCTAssertTrue(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0), events: [friday, nextFriday]))
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(week), events: [friday, nextFriday]))
    }

    func testAWholeSeriesBlocksEveryOccurrence() {
        let friday = event("Alex / Sam", in: 0, text: meet)
        let nextFriday = event("Alex / Sam", in: week, text: meet)
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(friday))
        XCTAssertEqual(book.choice(for: meeting(nextFriday)), .skipSeries)
        XCTAssertTrue(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(week), events: [friday, nextFriday]))
    }

    func testAnotherMeetingWithTheSameLinkKeepsRecording() {
        let oneOnOne = event("Alex / Sam", in: 0, text: meet)
        let other = event("Weekly Retro", in: 120, text: meet)
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(oneOnOne))
        XCTAssertEqual(book.choice(for: meeting(other)), .record)
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(120), events: [oneOnOne, other]))
    }

    func testJoiningAFewMinutesEarlyIsStillThatMeeting() {
        let e = event("Alex / Sam", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(e))
        XCTAssertTrue(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(-5), events: [e]))
    }

    func testTheSameLinkHoursBeforeTheMeetingIsNotThatMeeting() {
        let e = event("Alex / Sam", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(e))
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(-120), events: [e]))
    }

    func testACallWithADifferentMeetingCodeKeepsRecording() {
        let e = event("Alex / Sam", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(e))
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "xyz-abcd-efg", at: at(0), events: [e]))
    }

    func testTheZoomAppHasNoCodeSoTheOverlappingInviteDecides() {
        let e = event("Vendor", in: 0, text: "https://acme.zoom.us/j/123456789?pwd=secret")
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(e))
        XCTAssertTrue(book.blocks(platform: .zoom, meetingID: nil, at: at(2), events: [e]))
    }

    func testACallWithNoInviteKeepsRecording() {
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(event("Alex / Sam", in: 0, text: meet)))
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0), events: []))
    }

    func testChoosingAgainReplacesTheEarlierChoice() {
        let e = event("Alex / Sam", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipSeries, for: meeting(e))
        book.set(.skipThisMeeting, for: meeting(e))
        XCTAssertEqual(book.choice(for: meeting(event("Alex / Sam", in: week, text: meet))), .record)
        book.set(.record, for: meeting(e))
        XCTAssertEqual(book.choice(for: meeting(e)), .record)
        XCTAssertFalse(book.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0), events: [e]))
    }

    func testAPastOccurrenceIsForgottenButASeriesStays() {
        let one = event("One", in: 0, text: meet)
        let series = event("Series", in: 0, text: "https://meet.google.com/aaa-bbbb-ccc")
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(one))
        book.set(.skipSeries, for: meeting(series))
        book.removeExpired(now: at(60 * 24 * 2))
        XCTAssertEqual(book.choice(for: meeting(one)), .record)
        XCTAssertEqual(book.choice(for: meeting(series)), .skipSeries)
    }

    func testTheChoiceSurvivesARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(NoRecordBook.load(from: dir), NoRecordBook())
        let e = event("Alex / Sam", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(e))
        try book.save(to: dir)
        let loaded = NoRecordBook.load(from: dir)
        XCTAssertEqual(loaded.choice(for: meeting(e)), .skipThisMeeting)
        XCTAssertTrue(loaded.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0), events: [e]))
    }

    func testTheGateUsesTheLatestBookAndCalendar() {
        let e = event("Alex / Sam", in: 0, text: meet)
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: meeting(e))
        let gate = NoRecordGate()
        XCTAssertFalse(gate.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0)))
        gate.update(book: book)
        gate.update(events: [e])
        XCTAssertTrue(gate.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0)))
        gate.update(book: NoRecordBook())
        XCTAssertFalse(gate.blocks(platform: .meet, meetingID: "abc-defg-hij", at: at(0)))
    }
}
