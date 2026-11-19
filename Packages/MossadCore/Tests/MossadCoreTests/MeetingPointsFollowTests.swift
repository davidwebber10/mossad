import XCTest
@testable import MossadCore

/// A point of one meeting whose invite moved where neither its UID nor its title and start find it: it follows the
/// moved invite by its title and its sure people, only to an invite that is new in the whole read where its own went
/// away, and while no invite holds it, it waits in the row of meetings that were not recorded, never in no list.
final class MeetingPointsFollowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 10:00 in the owner's day, two hours from now.
    private var ten: Date { now.addingTimeInterval(2 * 3600) }
    private var original: UpcomingMeeting { invite(at: ten, uid: "uid-old") }

    private func detail(_ title: String = "Budget chat", at start: Date? = nil, event: String? = nil, people: [String]? = ["p-sam"],
                        invited: Int? = 1) -> MeetingDetail {
        let start = start ?? ten
        return MeetingDetail(title: title, start: start, end: start.addingTimeInterval(1800), event: event, people: people, invited: invited)
    }

    private func invite(_ title: String = "Budget chat", at start: Date, uid: String? = "uid-moved", recurring: Bool = false) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: start, end: start.addingTimeInterval(1800), attendees: ["Dana Lee", "Sam Carter"], platform: .meet,
                        link: nil, isRecurring: recurring, uid: uid)
    }

    /// A whole read: each invite with Sam alone unless `people` says otherwise; `before` is the previous whole read.
    private func read(_ invites: [UpcomingMeeting], before: [UpcomingMeeting]?, people: [String: [String]] = [:], count: [String: Int] = [:],
                      canonical: @escaping (String) -> String = { $0 }) -> MeetingPointRead {
        var p: [String: [String]] = [:], c: [String: Int] = [:]
        for u in invites {
            p[u.id] = people[u.id] ?? ["p-sam"]
            c[u.id] = count[u.id] ?? p[u.id]!.count
        }
        return MeetingPointRead(invites: invites, before: before, people: p, invited: c, canonical: canonical, calendar: utc)
    }

    private func book(_ details: MeetingDetail...) -> NextTimeBook {
        var book = NextTimeBook()
        for (i, d) in details.enumerated() { _ = book.add("Point \(i)", meeting: NextTimeMeeting(d), at: now.addingTimeInterval(-3600)) }
        return book
    }

    private func follow(_ b: inout NextTimeBook, _ r: MeetingPointRead?, at date: Date? = nil, records: [CallRecord] = []) -> Bool {
        b.followMeetings(upcoming: r?.invites ?? [], series: [], records: records, at: date ?? now, read: r)
    }

    // MARK: Following a moved invite

    func testAMoveTheSameDayWithNoEventHashFollows() {
        var b = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertTrue(follow(&b, read([moved], before: [original])))
        let d = b.points[0].meeting?.detail
        XCTAssertEqual(d?.start, moved.start)
        XCTAssertEqual(d?.end, moved.end)
        XCTAssertEqual(d?.event, NextTimeMeeting.event("uid-moved"))
        XCTAssertEqual(b.points(forMeeting: moved).count, 1)
        // Once followed, it is the invite's: nothing more changes.
        XCTAssertFalse(follow(&b, read([moved], before: [moved])))
    }

    func testAMoveOfTheSameUIDToANewStartIsNew() {
        // A repeated invite whose one meeting moved keeps its UID: the start makes it new.
        var b = book(detail())
        let old = invite(at: ten, uid: "uid-1", recurring: true)
        let moved = invite(at: ten.addingTimeInterval(90 * 60), uid: "uid-1", recurring: true)
        XCTAssertTrue(follow(&b, read([moved], before: [old])))
        XCTAssertNil(b.points[0].meeting?.detail?.event)
        XCTAssertEqual(b.points[0].meeting?.detail?.start, moved.start)
    }

    func testTheEventHashStillFindsTheInvite() {
        var b = book(detail(event: NextTimeMeeting.event("uid-1")))
        var moved = invite("Budget chat, new room", at: ten.addingTimeInterval(3 * 86_400), uid: "uid-1")
        moved.attendees = ["Dana Lee", "Jo Park"]
        // No people needed and no whole read: the UID is enough.
        XCTAssertTrue(b.followMeetings(upcoming: [moved], series: [], records: [], at: now))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, moved.start)
        XCTAssertEqual(b.points[0].meeting?.detail?.title, "Budget chat, new room")
    }

    func testWithNoEarlierWholeReadNothingFollowsAndThePointWaits() {
        var b = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(follow(&b, read([moved], before: nil)))
        XCTAssertEqual(b.unrecorded(records: [], now: now, read: [moved]).count, 1)
    }

    func testAnInviteThatWasAlreadyThereIsAnotherMeeting() {
        // The meeting was cancelled; tomorrow's was in the read before: the point waits, it does not jump.
        var b = book(detail())
        let tomorrow = invite(at: ten.addingTimeInterval(86_400 - 1800), uid: "uid-tomorrow")
        XCTAssertFalse(follow(&b, read([tomorrow], before: [original, tomorrow])))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
        XCTAssertEqual(b.unrecorded(records: [], now: now, read: [tomorrow]).count, 1)
        // The meeting moved to after tomorrow's: only the new one is a candidate.
        let moved = invite(at: ten.addingTimeInterval(86_400 + 7200))
        XCTAssertTrue(follow(&b, read([tomorrow, moved], before: [original, tomorrow])))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, moved.start)
    }

    func testAMeetingWhoseInviteWasNotInTheReadBeforeDoesNotFollow() {
        // Its own invite did not go away in this read: nothing says it moved.
        var b = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(follow(&b, read([moved], before: [])))
    }

    func testTwoInvitesEquallyNearFollowNone() {
        var b = book(detail())
        let earlier = invite(at: ten.addingTimeInterval(-3600), uid: "uid-a")
        let later = invite(at: ten.addingTimeInterval(3600), uid: "uid-b")
        XCTAssertFalse(follow(&b, read([earlier, later], before: [original])))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
    }

    func testTheNearestNewInviteIsFollowed() {
        var b = book(detail())
        let near = invite(at: ten.addingTimeInterval(1800), uid: "uid-a")
        let far = invite(at: ten.addingTimeInterval(2 * 86_400), uid: "uid-b")
        XCTAssertTrue(follow(&b, read([far, near], before: [original])))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, near.start)
    }

    func testOtherPeopleFollowNone() {
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        for people in [["p-sam", "p-jo"], ["p-jo"], []] {
            var b = book(detail())
            XCTAssertFalse(follow(&b, read([moved], before: [original], people: [moved.id: people])))
            XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
        }
    }

    func testAnotherCountOfInvitedFollowsNone() {
        // The same saved person and a guest who is not saved: a group, not the 1:1 it was.
        var b = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(follow(&b, read([moved], before: [original], count: [moved.id: 2])))
        var unknown = book(detail(invited: nil))
        XCTAssertFalse(follow(&unknown, read([moved], before: [original])))
    }

    func testPeopleAreComparedByTheirIdOfNow() {
        // Sam was merged into another id after the point was made.
        var b = book(detail(people: ["p-sam-old"]))
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertTrue(follow(&b, read([moved], before: [original], canonical: { $0 == "p-sam-old" ? "p-sam" : $0 })))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, moved.start)
    }

    func testAMeetingWithNoSurePeopleFollowsNone() {
        var b = book(detail(people: nil, invited: 1))
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(follow(&b, read([moved], before: [original], people: [moved.id: []])))
    }

    func testAnotherTitleFollowsNone() {
        var b = book(detail())
        let moved = invite("Hiring sync", at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(follow(&b, read([moved], before: [original])))
    }

    func testSevenCalendarDaysOrMoreFollowsNone() {
        let weekLater = invite(at: ten.addingTimeInterval(7 * 86_400))
        var b = book(detail())
        XCTAssertFalse(follow(&b, read([weekLater], before: [original])))
        // Earlier in the day, seven calendar days on: still a week.
        let weekEarlierInDay = invite(at: ten.addingTimeInterval(7 * 86_400 - 9 * 3600))
        XCTAssertFalse(follow(&b, read([weekEarlierInDay], before: [original])))
        let sixDays = invite(at: ten.addingTimeInterval(6 * 86_400 + 12 * 3600))
        XCTAssertTrue(follow(&b, read([sixDays], before: [original])))
    }

    func testDaysAreCountedInTheOwnersTimeZone() {
        // 10:00 UTC is 05:00 in New York. An invite 6 days and 17 hours on is 03:00 UTC, 7 calendar days on in UTC,
        // and 22:00 the evening before in New York, 6 calendar days on there.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let moved = invite(at: ten.addingTimeInterval(6 * 86_400 + 17 * 3600))
        var r = read([moved], before: [original])
        var b = book(detail())
        XCTAssertFalse(follow(&b, r))
        r.calendar = ny
        XCTAssertTrue(follow(&b, r))
    }

    func testAnUnknownReadFollowsNone() {
        var b = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, read: nil))
    }

    func testAnInviteThatAnotherMeetingHoldsIsNotTaken() {
        let moved = invite(at: ten.addingTimeInterval(90 * 60), uid: "uid-other")
        // The other meeting's point matches the invite by its UID; this one lost its invite.
        let otherStart = moved.start.addingTimeInterval(-86_400)
        var b = book(detail(), detail(at: otherStart, event: NextTimeMeeting.event("uid-other")))
        _ = follow(&b, read([moved], before: [original, invite(at: otherStart, uid: "uid-other")]))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
        XCTAssertEqual(b.points[1].meeting?.detail?.start, moved.start)
    }

    func testTwoMeetingsCannotFollowToOneInviteInOnePass() {
        let tomorrow = ten.addingTimeInterval(86_400 - 1800)
        let kept = invite(at: ten.addingTimeInterval(86_400 + 5 * 3600), uid: "uid-kept")
        var b = book(detail(), detail(at: tomorrow))
        _ = follow(&b, read([kept], before: [original, invite(at: tomorrow, uid: "uid-tomorrow")]))
        let starts = b.points.map { $0.meeting?.detail?.start }
        XCTAssertEqual(starts.filter { $0 == kept.start }.count, 1)
    }

    func testTwoPointsOfOneMeetingFollowTogether() {
        var b = book(detail(), detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertTrue(follow(&b, read([moved], before: [original])))
        XCTAssertEqual(b.points(forMeeting: moved).count, 2)
    }

    func testAMeetingThatEndedDoesNotFollow() {
        // 11:30 today, not recorded, now 12:05: tomorrow's 9:30 is another meeting.
        let half = ten.addingTimeInterval(90 * 60)
        var b = book(detail(at: half))
        let tomorrow = invite(at: ten.addingTimeInterval(86_400 - 1800), uid: "uid-tomorrow")
        let at = half.addingTimeInterval(35 * 60)
        XCTAssertFalse(follow(&b, read([tomorrow], before: [invite(at: half)]), at: at))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, half)
    }

    func testAMeetingThatIsOverDoesNotFollow() {
        let past = now.addingTimeInterval(-86_400)
        var b = book(detail(at: past))
        let next = invite(at: now.addingTimeInterval(3600))
        XCTAssertFalse(follow(&b, read([next], before: [invite(at: past, uid: "uid-past")])))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, past)
    }

    // MARK: Never in no list

    func testAFuturePointWithNoInviteWaitsOnlyAfterAWholeRead() {
        let b = book(detail())
        let other = invite("Hiring sync", at: ten)
        XCTAssertEqual(b.unrecorded(records: [], now: now, read: [other]).count, 1)
        XCTAssertEqual(b.unrecorded(records: [], now: now, read: []).count, 1)
        // An unknown read changes nothing: before its time it is in its meeting's list only.
        XCTAssertTrue(b.unrecorded(records: [], now: now).isEmpty)
        XCTAssertTrue(b.unrecorded(records: [], now: now, read: nil).isEmpty)
    }

    func testAFuturePointWhoseInviteIsReadDoesNotWait() {
        let b = book(detail())
        XCTAssertTrue(b.unrecorded(records: [], now: now, read: [invite(at: ten)]).isEmpty)
    }

    func testAPointBeyondTheReadDoesNotWait() {
        let b = book(detail(at: now.addingTimeInterval(Double(UpcomingMeeting.days + 2) * 86_400)))
        XCTAssertTrue(b.unrecorded(records: [], now: now, read: []).isEmpty)
    }

    func testAMeetingThatRecordsNowDoesNotWait() {
        // A call that started early on the invite holds its points: they are that call's, not lost.
        let b = book(detail())
        var r = CallRecord(id: "c", platform: .meet, bundleID: "", start: ten.addingTimeInterval(-300), end: ten.addingTimeInterval(-300), status: .recording)
        r.calendarTitle = "Budget chat"
        r.plannedStart = ten
        XCTAssertTrue(b.unrecorded(records: [r], now: ten.addingTimeInterval(-120), read: []).isEmpty)
    }

    func testAFuturePointThatWaitsIsNotGivenToThePerson() {
        // The sure 1:1 rule is for a meeting that is over: a future one waits and stays the meeting's.
        var b = book(detail())
        XCTAssertFalse(b.followMeetings(upcoming: [], series: [], records: [], at: now, name: { _ in "Sam Carter" }, read: read([], before: [original])))
        XCTAssertTrue(b.points[0].isForMeeting)
    }
}
