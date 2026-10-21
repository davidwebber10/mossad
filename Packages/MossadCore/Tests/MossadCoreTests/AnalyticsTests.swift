import XCTest
@testable import MossadCore

final class AnalyticsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    private func call(_ id: String, _ start: Date, minutes: Double, platform: Platform = .meet, people: [String] = ["Mitch Haus"],
                      kind: String? = nil, ownerSeconds: Double = 60) -> CallRecord {
        var r = CallRecord(id: id, platform: platform, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.kind = kind
        r.speakerNames["me:A"] = "David Webber"
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: ownerSeconds, text: String(repeating: "word ", count: 100))]
        for (i, p) in people.enumerated() {
            let label = String(UnicodeScalar(UInt8(65 + i)))
            r.speakerNames["them:\(label)"] = p
            r.utterances.append(Utterance(track: .them, speakerLabel: label, start: 100, end: 160, text: "ok"))
        }
        r.actionItems = [ActionItem(owner: "David Webber", task: "T")]
        return r
    }

    // MARK: Prices

    func testClaudeCostUsesTheModelsPrices() {
        let opus = UsageEvent(date: Date(), callID: nil, service: .claude, purpose: .summary, model: "claude-opus-5-5",
                              inputTokens: 1_000_000, outputTokens: 100_000, cacheReadTokens: 1_000_000)
        XCTAssertEqual(Pricing.cost(opus), 4 + 2 + 0.2, accuracy: 0.0001)
        var sonnet = opus
        sonnet.model = "claude-sonnet-5-5"
        sonnet.cacheReadTokens = nil
        XCTAssertEqual(Pricing.cost(sonnet), 2 + 1, accuracy: 0.0001)
        var unknown = opus
        unknown.model = "something-new"
        XCTAssertEqual(Pricing.cost(unknown), Pricing.cost(opus), accuracy: 0.0001)
    }

    func testAssemblyAICostIsPerAudioHourWithSpeakerLabelsForBatch() {
        let batch = UsageEvent(date: Date(), callID: "c", service: .assemblyai, purpose: .transcription, model: "universal-3-5-pro", audioSeconds: 3600)
        XCTAssertEqual(Pricing.cost(batch), 0.21 + 0.02, accuracy: 0.0001)
        let live = UsageEvent(date: Date(), callID: "c", service: .assemblyai, purpose: .live, model: nil, audioSeconds: 1800)
        XCTAssertEqual(Pricing.cost(live), 0.075, accuracy: 0.0001)
    }

    // MARK: Log

    func testTheLogAppendsAndReadsBackEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = UsageLog(directory: dir)
        log.record(UsageEvent(date: date(10, 1), callID: "a", service: .claude, purpose: .coach, model: "claude-opus-5-5", inputTokens: 10, outputTokens: 5))
        UsageContext.$callID.withValue("b") {
            log.record(service: .assemblyai, purpose: .transcription, model: "universal-2", audioSeconds: 60, at: date(10, 2))
        }
        let events = log.all()
        XCTAssertEqual(events.map(\.callID), ["a", "b"])
        XCTAssertEqual(events.last?.audioSeconds, 60)
    }

    // MARK: Estimates

    func testCallsWithNoLoggedUsageGetEstimates() {
        let r = call("old", date(10, 1), minutes: 30)
        let logged = [UsageEvent(date: date(10, 2), callID: "new", service: .claude, purpose: .summary, model: "claude-opus-5-5", inputTokens: 1, outputTokens: 1)]
        let estimates = Pricing.estimates(for: [r, call("new", date(10, 2), minutes: 10)], logged: logged)
        XCTAssertEqual(Set(estimates.map(\.callID)), ["old"])
        XCTAssertTrue(estimates.allSatisfy(\.estimated))
        let transcription = estimates.first { $0.purpose == .transcription }
        XCTAssertEqual(transcription?.audioSeconds, 3600)
        XCTAssertNotNil(estimates.first { $0.purpose == .summary }?.inputTokens)
    }

    // MARK: Ranges

    func testRangePresetsAndThePreviousPeriod() {
        let now = date(10, 21, 15)
        let week = AnalyticsRange.last7Days.interval(now: now, calendar: cal)
        XCTAssertEqual(week.start, cal.startOfDay(for: date(10, 15)))
        XCTAssertEqual(week.end, now)
        let month = AnalyticsRange.thisMonth.interval(now: now, calendar: cal)
        XCTAssertEqual(month.start, date(10, 1, 0))
        XCTAssertEqual(AnalyticsRange.previous(month).end, month.start)
        XCTAssertEqual(AnalyticsRange.previous(month).duration, month.duration, accuracy: 1)
        let custom = AnalyticsRange.custom(date(9, 1, 0), date(9, 30, 0)).interval(now: now, calendar: cal)
        XCTAssertEqual(custom.end, date(10, 1, 0))
    }

    // MARK: Report

    func testReportTotalsBreakdownsAndCosts() {
        let calls = [
            call("a", date(10, 19, 9), minutes: 30, platform: .meet, people: ["Mitch Haus", "Ed Ng"], kind: "1:1"),
            call("b", date(10, 20, 14), minutes: 60, platform: .zoom, people: ["Mitch Haus"], kind: "Planning"),
            call("old", date(9, 1), minutes: 45),
        ]
        let usage = [
            UsageEvent(date: date(10, 19, 10), callID: "a", service: .assemblyai, purpose: .transcription, model: "universal-2", audioSeconds: 3600),
            UsageEvent(date: date(10, 19, 10), callID: "a", service: .claude, purpose: .summary, model: "claude-opus-5-5", inputTokens: 1_000_000, outputTokens: 0),
            UsageEvent(date: date(10, 20, 15), callID: "b", service: .claude, purpose: .coach, model: "claude-opus-5-5", inputTokens: 0, outputTokens: 100_000),
        ]
        let interval = DateInterval(start: date(10, 15, 0), end: date(10, 22, 0))
        let r = AnalyticsReport(records: calls, usage: usage, owner: "David Webber", interval: interval, calendar: cal)

        XCTAssertEqual(r.calls, 2)
        XCTAssertEqual(r.callSeconds, 90 * 60)
        XCTAssertEqual(r.averageSeconds, 45 * 60)
        XCTAssertEqual(r.longest?.id, "b")
        XCTAssertEqual(r.actionItems, 2)
        XCTAssertEqual(r.people.first?.name, "Mitch Haus")
        XCTAssertEqual(r.people.first?.calls, 2)
        XCTAssertEqual(r.people.count, 2)
        XCTAssertEqual(r.platforms.first { $0.name == "Zoom" }?.seconds, 3600)
        XCTAssertEqual(r.kinds.map(\.name).sorted(), ["1:1", "Planning"])
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.days.first { cal.isDate($0.date, inSameDayAs: date(10, 20)) }?.seconds, 3600)
        XCTAssertEqual(r.heat.first { $0.weekday == 2 && $0.hour == 9 }?.seconds, 1800)
        // 120 s of the owner out of 300 s of speech.
        XCTAssertEqual(r.talkShare ?? 0, 0.4, accuracy: 0.001)

        // 0.15 + 0.02 + 4 + 2, and no estimate for "b" because it has a logged event.
        XCTAssertEqual(r.cost.total, 6.17, accuracy: 0.0001)
        XCTAssertEqual(r.cost.byService[.claude] ?? 0, 6, accuracy: 0.0001)
        XCTAssertEqual(r.cost.byPurpose[.coach] ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(r.cost.estimatedShare, 0, accuracy: 0.0001)
        XCTAssertEqual(r.cost.perCallHour, 6.17 / 1.5, accuracy: 0.0001)
    }

    func testReportBucketsLongRangesByWeek() {
        let interval = DateInterval(start: date(6, 1, 0), end: date(10, 1, 0))
        let r = AnalyticsReport(records: [], usage: [], owner: "David Webber", interval: interval, calendar: cal)
        XCTAssertEqual(r.bucket, .week)
        XCTAssertLessThan(r.days.count, 20)
    }

    // MARK: Tags

    func testKnownTagsAreTheMostUsedFirstWithOneSpelling() {
        var a = call("a", date(10, 1), minutes: 10); a.tags = ["Budget", "Databricks"]
        var b = call("b", date(10, 2), minutes: 10); b.tags = ["databricks"]
        var c = call("c", date(10, 3), minutes: 10); c.tags = ["Hiring"]
        XCTAssertEqual(Tags.known([a, b, c]), ["Databricks", "Budget", "Hiring"])
    }

    func testSearchMatchesTagsWithAHashAndInPlainText() {
        var r = call("a", date(10, 1), minutes: 10)
        r.calendarTitle = "Weekly sync"
        r.tags = ["Triple Whale"]
        XCTAssertTrue(MeetingSearch.matches(r, "#triple whale"))
        XCTAssertFalse(MeetingSearch.matches(r, "#triple"))
        XCTAssertTrue(MeetingSearch.matches(r, "whale"))
        XCTAssertTrue(MeetingSearch.matches(r, "weekly"))
        XCTAssertTrue(MeetingSearch.matches(r, "word"))
        XCTAssertFalse(MeetingSearch.matches(r, "nothing here"))
        XCTAssertTrue(MeetingSearch.matches(r, " "))
    }

    func testReportCountsTimePerTag() {
        var a = call("a", date(10, 19), minutes: 30); a.tags = ["Budget", "Databricks"]
        var b = call("b", date(10, 20), minutes: 60); b.tags = ["Databricks"]
        let r = AnalyticsReport(records: [a, b], usage: [], owner: "David Webber",
                                interval: DateInterval(start: date(10, 15, 0), end: date(10, 22, 0)), calendar: cal)
        XCTAssertEqual(r.tags.map(\.name), ["Databricks", "Budget"])
        XCTAssertEqual(r.tags.first?.calls, 2)
        XCTAssertEqual(r.tags.first?.seconds, 5400)
    }
}
