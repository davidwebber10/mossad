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

final class NoRecordGateSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let chrome = "com.google.Chrome"
    private let zoomApp = "us.zoom.xos"

    private func event(_ title: String, in minutes: Double, length: Double = 30, text: String) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                          attendees: [], text: text, isAllDay: false)
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func gate(blocking e: CalendarEventInfo, events: [CalendarEventInfo]? = nil) -> NoRecordGate {
        var book = NoRecordBook()
        book.set(.skipThisMeeting, for: UpcomingMeeting.from([e], now: now.addingTimeInterval(-86_400 * 2), days: 30)[0])
        let gate = NoRecordGate()
        gate.update(book: book)
        gate.update(events: events ?? [e])
        return gate
    }

    /// The meeting ran past its planned end, and a mic gap ended and started the call again: it once recorded.
    func testABlockedMeetingThatOverrunsStaysBlocked() {
        let e = event("Vendor", in: 0, text: "https://meet.google.com/abc-defg-hij")
        let g = gate(blocking: e)
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        XCTAssertTrue(g.isBlockingCall)
        XCTAssertTrue(g.callEnded(at: at(35)))
        XCTAssertFalse(g.isBlockingCall)
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(35.2)))
        XCTAssertTrue(g.callEnded(at: at(40)))
        // Long after, the same app records again.
        XCTAssertFalse(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(60)))
    }

    func testAnotherMeetingCodeInTheSameBrowserRecords() {
        let e = event("Vendor", in: 0, text: "https://meet.google.com/abc-defg-hij")
        let g = gate(blocking: e)
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        XCTAssertTrue(g.callEnded(at: at(31)))
        XCTAssertFalse(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "xyz-abcd-efg", at: at(32)))
        // A recorded call is not the blocked call: its end must stop the recording.
        XCTAssertFalse(g.callEnded(at: at(50)))
    }

    /// The Zoom app has no meeting code; the next invite after the blocked one decides.
    func testTheNextMeetingOnTheCalendarRecords() {
        let blocked = event("Vendor", in: 0, text: "https://acme.zoom.us/j/123456789")
        let next = event("Team sync", in: 30, text: "https://acme.zoom.us/j/987654321")
        let g = gate(blocking: blocked, events: [blocked, next])
        XCTAssertTrue(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(1)))
        XCTAssertTrue(g.callEnded(at: at(30)))
        XCTAssertFalse(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(31)))
    }

    /// Mossad was off, or restarted, during the blocked meeting: the call starts again and stays blocked.
    func testTheBlockSurvivesARestart() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = event("Vendor", in: 0, text: "https://acme.zoom.us/j/123456789")
        let first = gate(blocking: e)
        first.persistSession(in: dir)
        XCTAssertTrue(first.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(1)))
        first.seen(at: at(35))
        // A new run with no choice in the book and no calendar yet still blocks the same meeting.
        let second = NoRecordGate()
        second.persistSession(in: dir)
        XCTAssertTrue(second.isBlockingCall)
        XCTAssertTrue(second.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(36)))
    }

    /// Mossad was off for 25 minutes during a blocked Meet call that ran late; at turn-on the same code is back.
    func testOffThenOnLongAfterStaysBlockedForTheSameMeetingCode() {
        let e = event("Vendor", in: 0, text: "https://meet.google.com/abc-defg-hij")
        let g = gate(blocking: e)
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        g.seen(at: at(20))
        // No end was seen. Past the planned end, the call starts again.
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(45)))
        // The same code the next day is a new meeting, and the book decides.
        XCTAssertTrue(g.callEnded(at: at(50)))
        XCTAssertFalse(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(24 * 60)))
    }

    /// An app with no meeting code: the block ends 15 minutes after the planned end, and a blocked call does not
    /// renew it, so the calls after it are not lost one after the other.
    func testABlockWithNoMeetingCodeDoesNotChain() {
        let e = event("Vendor", in: 0, text: "https://acme.zoom.us/j/123456789")
        let g = gate(blocking: e)
        XCTAssertTrue(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(1)))
        XCTAssertTrue(g.callEnded(at: at(35)))
        // The meeting ran late and the owner joined again: still blocked, up to the planned end plus 15 minutes.
        XCTAssertTrue(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(36)))
        g.seen(at: at(44))
        XCTAssertTrue(g.callEnded(at: at(44.5)))
        XCTAssertFalse(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(46)), "one minute after the last call, but past the limit")
        XCTAssertFalse(g.callEnded(at: at(60)))
    }

    /// The owner left the blocked meeting and joined a different meeting that overlaps it.
    func testADifferentInviteThatOverlapsRecords() {
        let blocked = event("Vendor", in: 0, length: 60, text: "https://acme.zoom.us/j/123456789")
        let other = event("Team sync", in: 30, length: 30, text: "https://acme.zoom.us/j/987654321")
        let g = gate(blocking: blocked, events: [other, blocked])
        XCTAssertTrue(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(1)))
        XCTAssertTrue(g.callEnded(at: at(25)))
        XCTAssertFalse(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(30)))
        XCTAssertFalse(g.callEnded(at: at(60)))
    }

    /// The owner's Record on a warning always records.
    func testTheOwnersRecordWinsOverTheBlock() {
        let e = event("Vendor", in: 0, text: "https://meet.google.com/abc-defg-hij")
        let g = gate(blocking: e)
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        XCTAssertTrue(g.callEnded(at: at(10)))
        XCTAssertFalse(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: nil, at: at(12), forced: true))
        XCTAssertFalse(g.isBlockingCall)
        XCTAssertFalse(g.callEnded(at: at(20)), "the forced call records, so its end must stop the recording")
        // Also during the blocked meeting itself.
        XCTAssertFalse(gate(blocking: e).blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1), forced: true))
    }

    /// A team uses one link for each meeting. Mossad quit during the blocked one; the next one, which the owner
    /// did not mark, records.
    func testTheSameLinkInALaterInviteRecords() {
        let blocked = event("Standup", in: 0, text: "https://meet.google.com/abc-defg-hij")
        let later = event("Standup", in: 120, text: "https://meet.google.com/abc-defg-hij")
        let g = gate(blocking: blocked, events: [blocked, later])
        XCTAssertTrue(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(1)))
        g.seen(at: at(20))
        XCTAssertFalse(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(121)))
    }

    /// The owner changed the choice to Record during the meeting: the next start records.
    func testAChangedChoiceEndsTheBlock() {
        let e = event("Vendor", in: 0, text: "https://acme.zoom.us/j/123456789")
        let g = gate(blocking: e)
        XCTAssertTrue(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(1)))
        XCTAssertTrue(g.callEnded(at: at(5)))
        g.update(book: NoRecordBook())
        XCTAssertFalse(g.blocksStart(platform: .zoom, bundleID: zoomApp, meetingID: nil, at: at(6)))
    }

    func testACallWithNoBlockRecords() {
        let g = NoRecordGate()
        XCTAssertFalse(g.blocksStart(platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij", at: at(0)))
        XCTAssertFalse(g.callEnded(at: at(10)))
    }

    /// At launch the calendar comes a moment after detection: a call waits for it, but never for long.
    func testTheFirstCallWaitsForTheCalendar() {
        let g = NoRecordGate()
        let began = Date()
        g.waitForCalendar(timeout: 0.2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.19)
        // A calendar that never answers delays the first call only.
        let again = Date()
        g.waitForCalendar(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.1)
        let second = NoRecordGate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { second.update(events: []) }
        let start = Date()
        second.waitForCalendar(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let quick = Date()
        second.waitForCalendar(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(quick), 0.1)
    }
}
