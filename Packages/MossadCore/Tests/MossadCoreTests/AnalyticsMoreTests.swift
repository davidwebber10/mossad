import XCTest
@testable import MossadCore

/// The redesigned Analytics and People numbers (docs/superpowers/specs/2026-10-26-design-overhaul.md).
final class AnalyticsMoreTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Oct 19, 2026 is a Monday.
    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }

    private typealias Line = (key: String, start: Double, end: Double, text: String)

    private func call(_ id: String, _ start: Date, minutes: Double, names: [String: String], _ lines: [Line] = [],
                      scheduled: Bool = true) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.speakerNames = names
        r.calendarTitle = scheduled ? "Planned" : nil
        r.utterances = lines.map { l in
            let parts = l.key.split(separator: ":")
            return Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: l.start, end: l.end, text: l.text)
        }
        return r
    }

    private let trio = ["me:A": "Dana", "them:A": "Sam", "them:B": "Jo"]

    // MARK: Exchange

    func testTheExchangeCountsSpeechQuestionsInterruptionsAndReplies() {
        let r = call("x", date(19, 9), minutes: 30, names: trio, [
            ("them:A", 0, 10, "Morning. Ready?"),
            ("me:A", 12, 20, "Yes. Can we start?"),
            ("them:A", 18, 30, "Sure, I will start now."),
            ("them:B", 31, 35, "Me too?"),
        ])
        let x = Exchange(record: r)
        XCTAssertEqual(x.speech("Dana"), 8)
        XCTAssertEqual(x.speech("Sam"), 22)
        XCTAssertEqual(x.questions("Dana"), 1)
        XCTAssertEqual(x.questions("Sam"), 1)
        XCTAssertEqual(x.interruptions(by: "Sam", of: "Dana"), 1, "Sam starts 2 s before Dana ends")
        XCTAssertEqual(x.interruptions(by: "Dana"), 0)
        XCTAssertEqual(x.firstSpeaker, "Sam")
        XCTAssertEqual(x.replyGaps(to: "Sam", from: "Dana"), [2])
        XCTAssertEqual(x.replyGaps(to: "Dana", from: "Sam"), [], "an overlap is not a reply")
        XCTAssertEqual(x.replyGaps(to: "Sam", from: "Jo"), [1])
    }

    func testAShortReplyOrATalkOverIsNotCuttingIn() {
        let r = call("y", date(19, 9), minutes: 30, names: trio, [
            ("them:A", 0, 20, "Here is the plan for the quarter."),
            ("me:A", 5, 6, "Yeah."),
            ("me:A", 8, 12, "Right, and the budget too"),
            ("me:A", 25, 30, "So what comes next then?"),
            ("them:A", 27, 40, "Next we ship the new plan."),
        ])
        let x = Exchange(record: r)
        XCTAssertEqual(x.interruptions(by: "Dana"), 0, "a backchannel, and a line Sam talks through")
        XCTAssertEqual(x.interruptions(by: "Sam"), 1, "Sam takes the floor and Dana stops")
    }

    // MARK: Report

    private func week() -> [CallRecord] {
        [
            call("a", date(19, 9), minutes: 60, names: ["me:A": "Dana", "them:A": "Sam"], [
                ("me:A", 0, 600, "Where are we?"), ("them:A", 600, 1800, "Fine."), ("me:A", 1790, 1830, "Wait, one more thing here"),
            ]),
            call("b", date(19, 10, 3), minutes: 30, names: trio, [
                ("me:A", 0, 300, "Go."), ("them:A", 300, 900, "Ok."), ("them:B", 900, 1500, "Ok."),
            ], scheduled: false),
            call("c", date(21, 14), minutes: 60, names: ["me:A": "Dana", "them:A": "Sam"], [
                ("me:A", 0, 1800, "Hi."), ("them:A", 1800, 2400, "Hi."),
            ]),
        ]
    }

    private func report(_ records: [CallRecord], commitments: [Commitment] = []) -> AnalyticsReport {
        AnalyticsReport(records: records, usage: [], owner: "Dana", interval: DateInterval(start: date(19, 0), end: date(24, 0)),
                        commitments: commitments, calendar: cal)
    }

    func testTheWorkDayLoadCountsHoursBackToBackCallsAndFreeDays() {
        let w = report(week()).workday
        XCTAssertEqual(w.workdays, 5)
        XCTAssertEqual(w.hoursPerWorkday, 0.5, accuracy: 0.001)
        XCTAssertEqual(w.backToBackShare!, 1.0 / 3, accuracy: 0.001, "the 10:03 call starts 3 min after the 9:00 call ends")
        XCTAssertEqual(w.callFreeDays, 3)
        XCTAssertEqual(w.coreHoursShare, 2.5 / 50, accuracy: 0.001, "2.5 h of the 8:00 to 18:00 hours on 5 days")
    }

    func testCommunicationIsPerCallHourAndSplitsOneOnOnesFromGroups() {
        let c = report(week()).communication
        XCTAssertEqual(c.questionsPerHour!, 1 / 2.5, accuracy: 0.001)
        XCTAssertEqual(c.interruptionsMadePerHour!, 1 / 2.5, accuracy: 0.001, "Dana's 'Wait' cuts in on Sam")
        XCTAssertEqual(c.interruptionsReceivedPerHour!, 0, accuracy: 0.001)
        XCTAssertEqual(c.oneOnOneShare!, (640.0 + 1800) / (640 + 1800 + 1200 + 600), accuracy: 0.001)
        XCTAssertEqual(c.groupShare!, 300.0 / 1500, accuracy: 0.001)
        XCTAssertEqual(c.points.map(\.callID), ["a", "b", "c"])
    }

    func testOutcomesArePerCallHourAndCommitmentsCountWhenMadeInThePeriod() {
        var records = week()
        records[0].actionItems = [ActionItem(owner: "Dana", task: "Send"), ActionItem(owner: "Sam", task: "Check")]
        records[0].decisions = ["Ship Friday"]
        var done = Commitment(text: "Send", to: "Sam", callID: "a", callTitle: "A", madeAt: date(19, 9), due: nil)
        done.done = date(20, 9)
        let early = Commitment(text: "Old", to: nil, callID: nil, callTitle: nil, madeAt: date(1, 9), due: nil)
        let o = report(records, commitments: [done, early]).outcomes
        XCTAssertEqual(o.itemsPerHour, 2 / 2.5, accuracy: 0.001)
        XCTAssertEqual(o.decisionsPerHour, 1 / 2.5, accuracy: 0.001)
        XCTAssertEqual(o.withOutcomesShare!, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(o.mine, 1)
        XCTAssertEqual(o.others, 1)
        XCTAssertEqual(o.commitmentsMade, 1)
        XCTAssertEqual(o.commitmentsDone, 1)
    }

    func testThePeopleTableHasTalkBalanceLastMetAndATrend() {
        let r = report(week())
        let sam = r.people.first { $0.name == "Sam" }!
        XCTAssertEqual(sam.calls, 3)
        XCTAssertEqual(sam.mySpeech, 640 + 300 + 1800)
        XCTAssertEqual(sam.theirSpeech, 1200 + 600 + 600)
        XCTAssertEqual(sam.lastMet, date(21, 14))
        XCTAssertEqual(sam.trend, [2, 0, 1, 0, 0], "calls per day bucket")
        XCTAssertEqual(r.days[0].scheduledSeconds, 3600, "the 10:03 call had no invite")
    }

    // MARK: Ranges

    func testLastMonthAndStepping() {
        let now = date(26, 12)
        let last = AnalyticsRange.lastMonth.interval(now: now, calendar: cal)
        XCTAssertEqual(last.start, cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!)
        XCTAssertEqual(last.end, cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        let week = AnalyticsRange.last7Days.interval(now: now, calendar: cal)
        guard case .custom(let a, let b) = AnalyticsRange.step(week, by: -1, calendar: cal) else { return XCTFail("a step is a custom range") }
        XCTAssertEqual(a, date(13, 0))
        XCTAssertEqual(b, date(19, 0), "the last whole day before the week shown")
    }

    // MARK: Person

    func testAPersonsNumbersAreInRelationToTheOwner() {
        var records = week()
        records.append(call("d", date(26, 9), minutes: 30, names: ["me:A": "Dana", "them:A": "Sam"], [
            ("them:A", 0, 100, "Can you send it?"), ("me:A", 103, 200, "Yes."),
        ]))
        records[0].tags = ["Budget", "Hiring"]
        records[2].tags = ["Budget"]
        records[0].actionItems = [ActionItem(owner: "Sam", task: "Check the numbers")]
        let promise = Commitment(text: "Send the deck", to: "Sam", callID: "d", callTitle: "D", madeAt: date(26, 9), due: nil)
        var reviews: [String: CoachReview] = [:]
        var review = CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil, value: nil, delivery: nil)
        review.value = MeetingValue(rating: .high, reason: "", action: .keep, suggestion: "")
        reviews["a"] = review
        let p = PersonRelation(name: "Sam", owner: "Dana", records: records, reviews: reviews, commitments: [promise],
                               now: date(26, 12), calendar: cal)
        XCTAssertEqual(p.calls, 4)
        XCTAssertEqual(p.oneOnOne!.mine, 640 + 1800 + 97)
        XCTAssertEqual(p.oneOnOne!.theirs, 1200 + 600 + 100)
        XCTAssertEqual(p.group!.mine, 300)
        XCTAssertEqual(p.lastMet, date(26, 9))
        XCTAssertEqual(p.weekly.suffix(2).map(\.calls), [3, 1])
        XCTAssertEqual(p.ownerFirst, 3)
        XCTAssertEqual(p.theyFirst, 1)
        XCTAssertEqual(p.myReply, 3, "Dana answers Sam's question after 3 s")
        XCTAssertEqual(p.theyInterruptPerHour, 0)
        XCTAssertEqual(p.topics, ["Budget", "Hiring"])
        XCTAssertEqual(p.theirItems.map(\.task), ["Check the numbers"])
        XCTAssertEqual(p.myCommitments.map(\.text), ["Send the deck"])
        XCTAssertEqual(p.value[.high], 1)
        XCTAssertEqual(p.usualSlot?.weekday, 2, "Monday")
    }
}
