import XCTest
@testable import MossadCore

final class CutPlanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    private func record(_ length: TimeInterval = 3600, link: String? = "aaa-aaaa-aaa", firstTitle: String? = "weekly") -> CallRecord {
        var r = CallRecord(id: "20261101-100000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + length, status: .recorded)
        r.meetingID = link
        r.firstTitleKey = firstTitle
        return r
    }

    private func sure(_ at: TimeInterval, _ link: String) -> CallMark {
        CallMark(at: at, time: t0 + at, link: link, platform: .meet, source: .tabs, sure: true)
    }

    private func title(_ at: TimeInterval, _ key: String) -> CallMark {
        CallMark(at: at, time: t0 + at, link: nil, platform: .meet, source: .title, sure: false, titleKey: key)
    }

    private func title(_ at: TimeInterval, _ key: String, ownLinkInMeeting: Bool?) -> CallMark {
        var m = title(at, key)
        m.ownLinkInMeeting = ownLinkInMeeting
        return m
    }

    private func adopted(_ at: TimeInterval, _ link: String) -> CallMark {
        CallMark(at: at, time: t0 + at, link: link, platform: .meet, source: .tabs, sure: false)
    }

    /// An event with a Meet link of its own unless `link` is nil.
    private func event(_ from: TimeInterval, _ to: TimeInterval, link: String? = "ccc-cccc-ccc", declined: Bool = false) -> CalendarEventInfo {
        var e = CalendarEventInfo(title: "Event", start: t0 + from, end: t0 + to, attendees: [],
                                  text: link.map { "https://meet.google.com/\($0)" } ?? "", isAllDay: false)
        if declined { e.participants = [Invitee(name: "Avery Webb", email: "avery@example.com", isSelf: true, response: "declined")] }
        return e
    }

    private func cuts(_ r: CallRecord, _ marks: [CallMark], events: [CalendarEventInfo]? = [], length: TimeInterval = 3600) -> [TimeInterval] {
        var r = r
        r.callMarks = marks
        return CutPlan.decide(r, events: events, length: length).cuts.map(\.at)
    }

    func testNoMarkNoCut() {
        XCTAssertEqual(cuts(record(), []), [])
        let r = record()
        XCTAssertEqual(CutPlan.decide(r, events: [event(1800, 3600)], length: 3600).cuts, [], "the calendar alone never cuts")
    }

    func testASureMarkToAnotherLinkCuts() {
        var r = record()
        r.callMarks = [sure(1800, "bbb-bbbb-bbb")]
        let plan = CutPlan.decide(r, events: [], length: 3600)
        XCTAssertEqual(plan.cuts, [Cut(at: 1800, link: "bbb-bbbb-bbb")])
        XCTAssertEqual(cuts(record(), [sure(1800, "bbb-bbbb-bbb")], events: nil), [1800], "a sure mark needs no calendar")
        XCTAssertEqual(cuts(record(link: nil), [sure(1800, "bbb-bbbb-bbb")]), [1800], "a first part with no link")
    }

    func testASureMarkToTheSameLinkIsNoChange() {
        XCTAssertEqual(cuts(record(), [sure(1800, "aaa-aaaa-aaa")]), [])
    }

    func testABreakoutRoomIsOneMeeting() {
        let marks = [sure(1200, "bbb-bbbb-bbb"), sure(2400, "aaa-aaaa-aaa")]
        XCTAssertEqual(cuts(record(), marks, events: [event(0, 3600, link: "aaa-aaaa-aaa")]), [], "back to the first link, no event for the other")
        XCTAssertEqual(cuts(record(), marks, events: nil), [], "a calendar that could not be read holds no other link")
        XCTAssertEqual(cuts(record(), marks, events: [event(1200, 2400, link: "bbb-bbbb-bbb")]), [1200, 2400],
                       "an event holds the other link: three meetings")
    }

    func testATitleMarkCutsOnlyWithAnotherEventNearIt() {
        let first = event(-300, 1800, link: "aaa-aaaa-aaa")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first]), [], "no other event")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: nil), [], "the calendar could not be read")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first, event(1800 - 600, 3600)]), [1800], "10 minutes before")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first, event(1800 + 900, 3600)]), [1800], "15 minutes after")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first, event(1800 - 601, 3600)]), [], "more than 10 minutes before")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first, event(1800 + 901, 3600)]), [], "more than 15 minutes after")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first, event(1800, 3600, declined: true)]), [], "a declined event")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [event(1700, 3600, link: "aaa-aaaa-aaa")]), [],
                       "the event of the first part itself")
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: [first, event(1800, 3600), event(1850, 3600)]), [1800],
                       "two events in the window: any one is enough")
    }

    func testATitleMarkWithTheFirstTitleBackIsOneMeeting() {
        let events = [event(1800, 3600)]
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff"), title(2400, "weekly")], events: events), [])
        XCTAssertEqual(cuts(record(), [title(1800, "weekly")], events: events), [], "the first title itself is no change")
    }

    func testAnAdoptedLinkNeedsTheCalendar() {
        let events = [event(1800, 3600)]
        XCTAssertEqual(cuts(record(link: nil), [adopted(1800, "bbb-bbbb-bbb")], events: []), [])
        XCTAssertEqual(cuts(record(link: nil), [adopted(1800, "bbb-bbbb-bbb")], events: events), [1800])
        XCTAssertEqual(cuts(record(), [adopted(1800, "bbb-bbbb-bbb"), sure(2400, "aaa-aaaa-aaa")], events: events), [],
                       "back to the first link")
    }

    func testMarksOfOneChangeAreOneChange() {
        // The title mark first, the sure mark of the same change 40 s later: one cut at the earlier time, with the link.
        var r = record()
        r.callMarks = [title(1800, "kickoff"), sure(1840, "bbb-bbbb-bbb")]
        let plan = CutPlan.decide(r, events: [], length: 3600)
        XCTAssertEqual(plan.cuts, [Cut(at: 1800, link: "bbb-bbbb-bbb", titleKey: "kickoff")])
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff"), sure(1861, "bbb-bbbb-bbb")]), [1861], "61 s apart: two changes")
    }

    func testNoCutNearTheStartTheEndOrAnotherCut() {
        XCTAssertEqual(cuts(record(), [sure(59, "bbb-bbbb-bbb")]), [])
        XCTAssertEqual(cuts(record(), [sure(60, "bbb-bbbb-bbb")]), [60])
        XCTAssertEqual(cuts(record(), [sure(3541, "bbb-bbbb-bbb")]), [])
        XCTAssertEqual(cuts(record(), [sure(3540, "bbb-bbbb-bbb")]), [3540])
        // Marks within 60 s are one change, so two changes are always more than the minimum apart.
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1061, "ccc-cccc-ccc")]), [1000, 1061], "61 s: two changes, two cuts")
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1059, "ccc-cccc-ccc")]), [1000], "59 s: one change")
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1200, "ccc-cccc-ccc")]), [1000, 1200])
    }

    func testTheReasonsHoldNoTitleAndNoLink() {
        var r = record()
        r.callMarks = [title(1800, "kickoff"), sure(2400, "bbb-bbbb-bbb")]
        let plan = CutPlan.decide(r, events: [event(1800, 3600)], length: 3600)
        XCTAssertFalse(plan.reasons.isEmpty)
        for reason in plan.reasons {
            XCTAssertFalse(reason.contains("kickoff") || reason.contains("bbb") || reason.contains("Event"), reason)
        }
    }

    // MARK: The release review

    /// I1: a look of 30 s at the next meeting's page, and back: one meeting.
    func testI1ALookOf30SecondsAtTheNextMeetingsPageIsNoCut() {
        let events = [event(-300, 1800, link: "aaa-aaaa-aaa"), event(1920, 3600)]
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff"), title(1830, "weekly")], events: events), [])
    }

    /// I1: a visit of 40 s to a room and back: one meeting, also when an event holds the room's link.
    func testI1AVisitOf40SecondsToARoomIsNoCut() {
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1040, "aaa-aaaa-aaa")]), [])
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1040, "aaa-aaaa-aaa")], events: [event(900, 1500, link: "bbb-bbbb-bbb")]), [])
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1040, "ccc-cccc-ccc")]), [1000],
                       "two sure marks to two links are two changes, and the second is too near the first")
    }

    /// I2: the next meeting's page opened at 1800 (a title mark), the move to it at 1980 (a sure mark): one cut, at 1980.
    func testI2ATitleMarkThenTheSureMarkOfTheSameMoveIsOneCut() {
        let events = [event(-300, 1800, link: "aaa-aaaa-aaa"), event(1920, 3600, link: "bbb-bbbb-bbb")]
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff"), sure(1980, "bbb-bbbb-bbb")], events: events), [1980])
    }

    /// I2: the next meeting's page stays in front while the call's own tab is still in its meeting: no cut. Unknown or
    /// not in its meeting: the calendar decides.
    func testI2ATitleMarkWhileTheOwnTabIsInItsMeetingIsNoCut() {
        let events = [event(-300, 1800, link: "aaa-aaaa-aaa"), event(1920, 3600)]
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff", ownLinkInMeeting: true)], events: events), [])
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff", ownLinkInMeeting: false)], events: events), [1800])
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff", ownLinkInMeeting: nil)], events: events), [1800])
    }

    /// I3: a 1:1, then a workshop with one visit to a breakout room: two meetings.
    func testI3ABreakoutRoomInTheSecondCall() {
        let marks = [sure(1000, "bbb-bbbb-bbb"), sure(2000, "xxx-xxxx-xxx"), sure(2600, "bbb-bbbb-bbb")]
        XCTAssertEqual(cuts(record(), marks), [1000])
    }

    /// I3: there, back, and there again (the last session in the room): one meeting.
    func testI3ThereBackAndThereAgainIsOneMeeting() {
        XCTAssertEqual(cuts(record(), [sure(1000, "xxx-xxxx-xxx"), sure(1600, "aaa-aaaa-aaa"), sure(2400, "xxx-xxxx-xxx")]), [])
    }

    /// I3: a change in the first minute makes no cut but is the link of the part from then on.
    func testI3AChangeInTheFirstMinuteThenABreakoutVisit() {
        XCTAssertEqual(cuts(record(), [sure(30, "bbb-bbbb-bbb"), sure(1000, "xxx-xxxx-xxx"), sure(1600, "bbb-bbbb-bbb")]), [])
    }

    /// I4: an event with no call link ("Lunch") is no proof of another call.
    func testI4AnEventWithNoCallLinkDoesNotAgree() {
        let events = [event(-300, 1800, link: "aaa-aaaa-aaa"), event(1800, 3600, link: nil)]
        XCTAssertEqual(cuts(record(), [title(1800, "kickoff")], events: events), [])
    }

    /// I4: the same invite in two calendars is the part's own event twice.
    func testI4ASecondCopyOfTheOwnEventDoesNotAgree() {
        var own = event(-300, 3000, link: "aaa-aaaa-aaa")
        own.iCalUID = "uid-1"
        var copy = own
        copy.source = .google
        copy.calendarAccount = "avery@example.com"
        XCTAssertEqual(cuts(record(), [title(240, "weekly-name")], events: [own, copy]), [], "the same iCalUID")
        copy.iCalUID = nil
        copy.text = "Join: https://meet.google.com/aaa-aaaa-aaa?hs=1"
        XCTAssertEqual(cuts(record(), [title(240, "weekly-name")], events: [own, copy]), [], "the same call link")
        var titled = CalendarEventInfo(title: own.title, start: own.start, end: own.end, attendees: [], text: "https://meet.google.com/zzz-zzzz-zzz",
                                       isAllDay: false)
        titled.source = .google
        XCTAssertEqual(cuts(record(), [title(240, "weekly-name")], events: [own, titled]), [], "the same title and start")
    }

    /// I4: an adopted link that is the meeting's own is no change.
    func testI4AnAdoptedLinkThatIsTheMeetingsOwnIsNoChange() {
        let events = [event(0, 3600, link: "aaa-aaaa-aaa"), event(1800, 3600)]
        XCTAssertEqual(cuts(record(link: nil), [adopted(1800, "aaa-aaaa-aaa")], events: events), [])
    }

    /// I5: the replay of 2026-11-17 with no event before 16:00: the next meeting's event overlaps the first call by two
    /// minutes only, so it is the candidate for the next call, not the first call's own.
    func testI5TheReplayWithNoEventBeforeTheNextMeeting() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { c.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: h, minute: m, second: s))! }
        let start = at(14, 34, 6), length: TimeInterval = 146 * 60
        var r = CallRecord(id: "20261117-143406", platform: .meet, bundleID: "com.google.Chrome", start: start, end: start + length, status: .recorded)
        r.firstTitleKey = CallTitleWatch.key("Design review")
        let next = CalendarEventInfo(title: "Made-up", start: at(16, 0), end: at(16, 45), attendees: [], text: "https://meet.google.com/ddd-dddd-ddd",
                                     isAllDay: false)
        r.callMarks = [CallMark(at: 5290, time: start + 5290, link: nil, platform: .meet, source: .title, sure: false, titleKey: CallTitleWatch.key("Kickoff"))]
        XCTAssertEqual(CutPlan.decide(r, events: [next], length: length).cuts.map(\.at), [5290])
    }

    /// I6: the marks of a wrong change that the watch took back 20 s later: one meeting.
    func testI6AWrongSureMarkTakenBackIsNoCut() {
        XCTAssertEqual(cuts(record(), [sure(1000, "bbb-bbbb-bbb"), sure(1020, "aaa-aaaa-aaa")], events: [event(900, 3600, link: "bbb-bbbb-bbb")]), [])
    }

    /// The meeting of 2026-11-17, with made-up names: one recording from 14:34:06 for 146 minutes with no link, a
    /// title mark at 5290 s, the first event 14:30 to 15:00, two at 15:00, and one from 16:00 to 16:45.
    func testTheReplayOf20261117() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { c.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: h, minute: m, second: s))! }
        let start = at(14, 34, 6), length: TimeInterval = 146 * 60
        var r = CallRecord(id: "20261117-143406", platform: .meet, bundleID: "com.google.Chrome", start: start, end: start + length, status: .recorded)
        r.firstTitleKey = CallTitleWatch.key("Design review")
        func e(_ from: Date, _ to: Date, _ code: String) -> CalendarEventInfo {
            CalendarEventInfo(title: "Made-up", start: from, end: to, attendees: [], text: "https://meet.google.com/\(code)", isAllDay: false)
        }
        let events = [e(at(14, 30), at(15, 0), "aaa-aaaa-aaa"), e(at(15, 0), at(15, 30), "bbb-bbbb-bbb"),
                      e(at(15, 0), at(16, 0), "ccc-cccc-ccc"), e(at(16, 0), at(16, 45), "ddd-dddd-ddd")]
        let mark = CallMark(at: 5290, time: start + 5290, link: nil, platform: .meet, source: .title, sure: false,
                            titleKey: CallTitleWatch.key("Kickoff"))
        r.callMarks = [mark]
        XCTAssertEqual(CutPlan.decide(r, events: events, length: length).cuts.map(\.at), [5290])
        r.callMarks = nil
        XCTAssertEqual(CutPlan.decide(r, events: events, length: length).cuts, [], "no title mark: no cut")
        r.callMarks = [mark, CallMark(at: 6000, time: start + 6000, link: nil, platform: .meet, source: .title, sure: false,
                                      titleKey: CallTitleWatch.key("Design review"))]
        XCTAssertEqual(CutPlan.decide(r, events: events, length: length).cuts, [], "the first title came back: no cut")
    }
}
