import XCTest
@testable import MossadCore

/// A point of one meeting whose invite moved where neither its UID nor its title and start find it: it follows the
/// moved invite by its title and its sure people, and while no invite holds it, it waits in the row of meetings that
/// were not recorded, never in no list.
final class MeetingPointsFollowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 10:00 in the owner's day, two hours from now.
    private var ten: Date { now.addingTimeInterval(2 * 3600) }

    private func detail(_ title: String = "Budget chat", at start: Date? = nil, event: String? = nil, people: [String]? = ["p-sam"]) -> MeetingDetail {
        let start = start ?? ten
        return MeetingDetail(title: title, start: start, end: start.addingTimeInterval(1800), event: event, people: people, invited: people?.count)
    }

    private func invite(_ title: String = "Budget chat", at start: Date, uid: String? = "uid-moved", recurring: Bool = false) -> UpcomingMeeting {
        UpcomingMeeting(title: title, start: start, end: start.addingTimeInterval(2700), attendees: ["Dana Lee", "Sam Carter"], platform: .meet,
                        link: nil, isRecurring: recurring, uid: uid)
    }

    private func book(_ details: MeetingDetail...) -> (NextTimeBook, [NextTimePoint]) {
        var book = NextTimeBook()
        let points = details.enumerated().map { i, d in book.add("Point \(i)", meeting: NextTimeMeeting(d), at: now.addingTimeInterval(-3600))! }
        return (book, points)
    }

    // MARK: Following a moved invite

    func testAMoveTheSameDayWithNoEventHashFollows() {
        var (b, _) = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertTrue(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true))
        let d = b.points[0].meeting?.detail
        XCTAssertEqual(d?.start, moved.start)
        XCTAssertEqual(d?.end, moved.end)
        XCTAssertEqual(d?.event, NextTimeMeeting.event("uid-moved"))
        XCTAssertEqual(b.points(forMeeting: moved).count, 1)
        // Once followed, it is the invite's: nothing more changes.
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true))
    }

    func testARepeatedInviteGivesNoEventHash() {
        var (b, _) = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60), recurring: true)
        XCTAssertTrue(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true))
        XCTAssertNil(b.points[0].meeting?.detail?.event)
        XCTAssertEqual(b.points[0].meeting?.detail?.start, moved.start)
    }

    func testTheEventHashStillFindsTheInvite() {
        var (b, _) = book(detail(event: NextTimeMeeting.event("uid-1")))
        var moved = invite("Budget chat, new room", at: ten.addingTimeInterval(3 * 86_400), uid: "uid-1")
        moved.attendees = ["Dana Lee", "Jo Park"]
        // No people needed and no whole read: the UID is enough.
        XCTAssertTrue(b.followMeetings(upcoming: [moved], series: [], records: [], at: now))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, moved.start)
        XCTAssertEqual(b.points[0].meeting?.detail?.title, "Budget chat, new room")
    }

    func testTwoInvitesEquallyNearFollowNone() {
        var (b, _) = book(detail())
        let earlier = invite(at: ten.addingTimeInterval(-3600), uid: "uid-a")
        let later = invite(at: ten.addingTimeInterval(3600), uid: "uid-b")
        let invited = [earlier.id: ["p-sam"], later.id: ["p-sam"]]
        XCTAssertFalse(b.followMeetings(upcoming: [earlier, later], series: [], records: [], at: now, invited: invited, calendarWhole: true))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
    }

    func testTheNearestInviteIsFollowed() {
        var (b, _) = book(detail())
        let near = invite(at: ten.addingTimeInterval(1800), uid: "uid-a")
        let far = invite(at: ten.addingTimeInterval(2 * 86_400), uid: "uid-b")
        let invited = [near.id: ["p-sam"], far.id: ["p-sam"]]
        XCTAssertTrue(b.followMeetings(upcoming: [far, near], series: [], records: [], at: now, invited: invited, calendarWhole: true))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, near.start)
    }

    func testOtherPeopleFollowNone() {
        var (b, _) = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam", "p-jo"]], calendarWhole: true))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-jo"]], calendarWhole: true))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [:], calendarWhole: true))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
    }

    func testAMeetingWithNoSurePeopleFollowsNone() {
        var (b, _) = book(detail(people: nil))
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: []], calendarWhole: true))
    }

    func testAnotherTitleFollowsNone() {
        var (b, _) = book(detail())
        let moved = invite("Hiring sync", at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true))
    }

    func testMoreThanSevenDaysFollowsNone() {
        var (b, _) = book(detail())
        let moved = invite(at: ten.addingTimeInterval(7 * 86_400 + 60))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true))
        let inside = invite(at: ten.addingTimeInterval(7 * 86_400 - 60))
        XCTAssertTrue(b.followMeetings(upcoming: [inside], series: [], records: [], at: now, invited: [inside.id: ["p-sam"]], calendarWhole: true))
    }

    func testAnUnknownReadFollowsNone() {
        var (b, _) = book(detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertFalse(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: false))
    }

    func testAnInviteThatAnotherMeetingHoldsIsNotTaken() {
        let moved = invite(at: ten.addingTimeInterval(90 * 60), uid: "uid-other")
        // The other meeting's point matches the invite by its UID; this one lost its invite.
        var (b, _) = book(detail(), detail(at: moved.start.addingTimeInterval(-86_400), event: NextTimeMeeting.event("uid-other")))
        b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true)
        XCTAssertEqual(b.points[0].meeting?.detail?.start, ten)
        XCTAssertEqual(b.points[1].meeting?.detail?.start, moved.start)
    }

    func testTwoPointsOfOneMeetingFollowTogether() {
        var (b, _) = book(detail(), detail())
        let moved = invite(at: ten.addingTimeInterval(90 * 60))
        XCTAssertTrue(b.followMeetings(upcoming: [moved], series: [], records: [], at: now, invited: [moved.id: ["p-sam"]], calendarWhole: true))
        XCTAssertEqual(b.points(forMeeting: moved).count, 2)
    }

    func testAMeetingThatIsOverDoesNotFollow() {
        let past = now.addingTimeInterval(-86_400)
        var (b, _) = book(detail(at: past))
        let next = invite(at: now.addingTimeInterval(3600))
        XCTAssertFalse(b.followMeetings(upcoming: [next], series: [], records: [], at: now, invited: [next.id: ["p-sam"]], calendarWhole: true))
        XCTAssertEqual(b.points[0].meeting?.detail?.start, past)
    }

    // MARK: Never in no list

    func testAFuturePointWithNoInviteWaitsOnlyAfterAWholeRead() {
        let (b, points) = book(detail())
        let other = invite("Hiring sync", at: ten)
        XCTAssertEqual(b.unrecorded(records: [], now: now, read: [other]).map(\.id), [points[0].id])
        XCTAssertEqual(b.unrecorded(records: [], now: now, read: []).map(\.id), [points[0].id])
        // An unknown read changes nothing: before its time it is in its meeting's list only.
        XCTAssertTrue(b.unrecorded(records: [], now: now).isEmpty)
        XCTAssertTrue(b.unrecorded(records: [], now: now, read: nil).isEmpty)
    }

    func testAFuturePointWhoseInviteIsReadDoesNotWait() {
        let (b, _) = book(detail())
        let same = invite(at: ten)
        XCTAssertTrue(b.unrecorded(records: [], now: now, read: [same]).isEmpty)
    }

    func testAPointBeyondTheReadDoesNotWait() {
        let (b, _) = book(detail(at: now.addingTimeInterval(Double(UpcomingMeeting.days + 2) * 86_400)))
        XCTAssertTrue(b.unrecorded(records: [], now: now, read: []).isEmpty)
    }

    func testAMeetingThatRecordsNowDoesNotWait() {
        // A call that started early on the invite holds its points: they are that call's, not lost.
        let (b, _) = book(detail())
        var r = CallRecord(id: "c", platform: .meet, bundleID: "", start: ten.addingTimeInterval(-300), end: ten.addingTimeInterval(-300), status: .recording)
        r.calendarTitle = "Budget chat"
        r.plannedStart = ten
        XCTAssertTrue(b.unrecorded(records: [r], now: ten.addingTimeInterval(-120), read: []).isEmpty)
    }

    func testAFuturePointThatWaitsIsNotGivenToThePerson() {
        // The sure 1:1 rule is for a meeting that is over: a future one waits and stays the meeting's.
        var (b, _) = book(detail())
        XCTAssertFalse(b.followMeetings(upcoming: [], series: [], records: [], at: now, name: { _ in "Sam Carter" }, calendarWhole: true))
        XCTAssertTrue(b.points[0].isForMeeting)
    }
}
