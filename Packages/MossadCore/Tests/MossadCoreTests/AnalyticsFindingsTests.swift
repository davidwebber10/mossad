import XCTest
@testable import MossadCore

/// The sentence that opens each Analytics section and states its finding.
final class AnalyticsFindingsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Oct 19, 2026 is a Monday.
    private func date(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    private func call(_ id: String, _ start: Date, minutes: Double, people: [String] = ["Sam Park"], scheduled: Bool = false,
                      tags: [String] = []) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.calendarTitle = scheduled ? "Planned" : nil
        r.tags = tags
        r.speakerNames["me:A"] = "Dana Lee"
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 60, text: "Hello there.")]
        for (i, p) in people.enumerated() {
            let label = String(UnicodeScalar(UInt8(65 + i)))
            r.speakerNames["them:\(label)"] = p
            r.utterances.append(Utterance(track: .them, speakerLabel: label, start: 100, end: 160, text: "ok"))
        }
        return r
    }

    private func report(_ records: [CallRecord], from: Date, to: Date, reviews: [String: CoachReview] = [:]) -> AnalyticsReport {
        AnalyticsReport(records: records, usage: [], owner: "Dana Lee", interval: DateInterval(start: from, end: to), reviews: reviews, calendar: cal)
    }

    // MARK: Ranges

    func testQuarterRanges() {
        let now = date(11, 6, 15)
        let this = AnalyticsRange.thisQuarter.interval(now: now, calendar: cal)
        XCTAssertEqual(this.start, date(10, 1, 0))
        XCTAssertEqual(this.end, now)
        let last = AnalyticsRange.lastQuarter.interval(now: now, calendar: cal)
        XCTAssertEqual(last.start, date(7, 1, 0))
        XCTAssertEqual(last.end, date(10, 1, 0))
    }

    // MARK: Words

    func testDurationsAndShares() {
        XCTAssertEqual(AnalyticsFindings.duration(14 * 3600 + 11 * 60 + 20), "14 h 11 min")
        XCTAssertEqual(AnalyticsFindings.duration(3 * 3600), "3 h")
        XCTAssertEqual(AnalyticsFindings.duration(45 * 60), "45 min")
        XCTAssertEqual(AnalyticsFindings.duration(10), "0 min")
        XCTAssertEqual(AnalyticsFindings.shareWords(0.33), "a third of")
        XCTAssertEqual(AnalyticsFindings.shareWords(0.4), "over a third of")
        XCTAssertEqual(AnalyticsFindings.shareWords(0.8), "most of")
        XCTAssertEqual(AnalyticsFindings.shareWords(0.07), "7% of")
    }

    // MARK: Sections

    func testTimeSaysTheWeeklyAverageForLongPeriods() {
        let r = report([call("a", date(10, 19), minutes: 120), call("b", date(10, 20), minutes: 60)], from: date(10, 8, 0), to: date(11, 5, 0))
        XCTAssertEqual(AnalyticsFindings.time(r), "3 h in calls, about 45 min a week")
        let short = report([call("a", date(10, 19), minutes: 120)], from: date(10, 15, 0), to: date(10, 22, 0))
        XCTAssertEqual(AnalyticsFindings.time(short), "2 h in 1 call")
    }

    func testScheduledSaysHowMuchIsOnTheCalendar() {
        let mostlyAdHoc = report([call("a", date(10, 19), minutes: 40, scheduled: true), call("b", date(10, 20), minutes: 60)],
                                 from: date(10, 15, 0), to: date(10, 22, 0))
        XCTAssertEqual(AnalyticsFindings.scheduled(mostlyAdHoc), "Over half is not on the calendar")
        let planned = report([call("a", date(10, 19), minutes: 60, scheduled: true)], from: date(10, 15, 0), to: date(10, 22, 0))
        XCTAssertEqual(AnalyticsFindings.scheduled(planned), "Almost all of it is on the calendar")
        let even = report([call("a", date(10, 19), minutes: 30, scheduled: true), call("b", date(10, 20), minutes: 30)],
                          from: date(10, 15, 0), to: date(10, 22, 0))
        XCTAssertEqual(AnalyticsFindings.scheduled(even), "Half of it is on the calendar")
    }

    func testBusiestHoursNameTheTwoFullestHours() {
        // Thursday Oct 22 at 11 for 60 min, Friday Oct 23 at 13 for 50 min, Monday at 9 for 10 min.
        let r = report([call("a", date(10, 22, 11), minutes: 60), call("b", date(10, 23, 13), minutes: 50), call("c", date(10, 19, 9), minutes: 10)],
                       from: date(10, 15, 0), to: date(10, 26, 0))
        XCTAssertEqual(AnalyticsFindings.busiestHours(r.heat), "Thursday at 11 and Friday at 1 are your busiest hours")
        let one = report([call("a", date(10, 22, 11), minutes: 30)], from: date(10, 15, 0), to: date(10, 26, 0))
        XCTAssertEqual(AnalyticsFindings.busiestHours(one.heat), "Thursday at 11 is your busiest hour")
        let sameDay = report([call("a", date(10, 22, 11), minutes: 120)], from: date(10, 15, 0), to: date(10, 26, 0))
        XCTAssertEqual(AnalyticsFindings.busiestHours(sameDay.heat), "Thursday at 11 and noon are your busiest hours")
        XCTAssertNil(AnalyticsFindings.busiestHours([]))
    }

    func testBusiestHoursSayNoonAndMidnightAndBreakTiesByTheEarlierHour() {
        // Monday 12 to 13 and Tuesday 0 to 1, the same time each: Monday comes first in the week.
        let r = report([call("a", date(10, 19, 12), minutes: 60), call("b", date(10, 20, 0), minutes: 60)],
                       from: date(10, 15, 0), to: date(10, 26, 0))
        XCTAssertEqual(AnalyticsFindings.busiestHours(r.heat), "Monday at noon and Tuesday at midnight are your busiest hours")
        // Three equal hours: the two earliest in a Monday-first week win.
        let tie = report([call("a", date(10, 25, 9), minutes: 30), call("b", date(10, 21, 15), minutes: 30), call("c", date(10, 19, 16), minutes: 30)],
                         from: date(10, 15, 0), to: date(10, 26, 0))
        XCTAssertEqual(AnalyticsFindings.busiestHours(tie.heat), "Monday at 4 and Wednesday at 3 are your busiest hours")
    }

    func testWorkdays() {
        var w = AnalyticsReport.Workday()
        XCTAssertNil(AnalyticsFindings.workdays(w))
        w.workdays = 22; w.callFreeDays = 16
        XCTAssertEqual(AnalyticsFindings.workdays(w), "Most work days have no calls")
        w.callFreeDays = 0
        XCTAssertEqual(AnalyticsFindings.workdays(w), "Every work day had a call")
        w.callFreeDays = 5
        XCTAssertEqual(AnalyticsFindings.workdays(w), "You had calls on 17 of 22 work days")
    }

    func testTopicsCountACallWithBothTagsOnce() {
        let r = report([call("a", date(10, 19), minutes: 60, tags: ["Budget", "Acme"]), call("b", date(10, 20), minutes: 30, tags: ["Acme"]),
                        call("c", date(10, 21), minutes: 90, tags: ["Hiring"]), call("d", date(10, 21, 15), minutes: 90)],
                       from: date(10, 15, 0), to: date(10, 22, 0))
        // Hiring 90 and Acme 90 (Budget is inside Acme's time): 180 of 270 minutes.
        XCTAssertEqual(AnalyticsFindings.topics(r), "Acme and Hiring took two thirds of your call time")
        let none = report([call("a", date(10, 19), minutes: 60)], from: date(10, 15, 0), to: date(10, 22, 0))
        XCTAssertNil(AnalyticsFindings.topics(none))
    }

    func testValueNamesTheTimeRatedLow() {
        func review(_ rating: MeetingValue.Rating) -> CoachReview {
            CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil,
                        value: MeetingValue(rating: rating, reason: "", action: .keep, suggestion: ""))
        }
        let calls = [call("a", date(10, 19), minutes: 90), call("b", date(10, 20), minutes: 30)]
        let r = report(calls, from: date(10, 15, 0), to: date(10, 22, 0), reviews: ["a": review(.low), "b": review(.high)])
        XCTAssertEqual(AnalyticsFindings.value(r), "1 h 30 min went to meetings the coach rated low")
        let good = report(calls, from: date(10, 15, 0), to: date(10, 22, 0), reviews: ["a": review(.high)])
        XCTAssertEqual(AnalyticsFindings.value(good), "The coach rated none of your meetings low")
        XCTAssertNil(AnalyticsFindings.value(report(calls, from: date(10, 15, 0), to: date(10, 22, 0))))
    }

    func testPeopleNamesTheTopShare() {
        let r = report([call("a", date(10, 19), minutes: 60, people: ["Sam Park"]), call("b", date(10, 20), minutes: 60, people: ["Alex Rivera"]),
                        call("c", date(10, 21), minutes: 20, people: ["Sam Park"])], from: date(10, 15, 0), to: date(10, 22, 0))
        XCTAssertEqual(AnalyticsFindings.people(r), "Sam Park is 57% of your call time")
    }

    func testCommunicationSaysTheLevelAndLeavesAChangeToTheCharts() {
        // The charts under the sentence say whether a number moved, by the trend's rules; the sentence over them
        // never says a change by a looser rule.
        var c = AnalyticsReport.Communication()
        c.groupShare = 0.23
        c.interruptionsMadePerHour = 6.1
        c.interruptionsReceivedPerHour = 4.2
        XCTAssertEqual(AnalyticsFindings.communication(c, talkShare: 0.29), "You talk 29% of the time; you cut in more than others do")
        c.interruptionsMadePerHour = 4
        XCTAssertEqual(AnalyticsFindings.communication(c, talkShare: nil), "You cut in about as often as others do")
        XCTAssertNil(AnalyticsFindings.communication(AnalyticsReport.Communication(), talkShare: nil))
    }

    func testOutcomes() {
        var o = AnalyticsReport.Outcomes()
        XCTAssertNil(AnalyticsFindings.outcomes(o))
        o.withOutcomesShare = 0.95
        o.commitmentsMade = 31; o.commitmentsDone = 3
        XCTAssertEqual(AnalyticsFindings.outcomes(o), "Almost every call produced an item or a decision; 3 of your 31 tasks are done")
        o.withOutcomesShare = 0.4
        o.commitmentsMade = 0
        XCTAssertEqual(AnalyticsFindings.outcomes(o), "40% of calls produced an item or a decision")
    }
}
