import XCTest
@testable import MossadCore

/// The owner's numbers per meeting across a period: the points, the line, the usual band, and the sentence.
final class CommunicationTrendsTests: XCTestCase {
    private typealias T = CommunicationTrends

    /// Midnight UTC, so a day of the period is a day of the calendar below.
    private let start = Date(timeIntervalSince1970: 1_790_035_200)
    private let owner = "Dana Lee"
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: Helpers

    private func period(_ days: Double = 90) -> DateInterval { DateInterval(start: start, duration: days * 86_400) }

    /// A meeting `day` days into the period (negative: before it) with the owner's numbers. `voices` people spoke.
    private func meeting(_ id: String, day: Double, share: Double? = 0.5, voices: Int = 3, questions: Double? = nil, cutIns: Double? = nil,
                         pace: Double? = nil, title: String = "Sync", withOwner: Bool = true, ownerMain: Bool = true,
                         wordTimes: Bool = true) -> MeetingFacts {
        var values: [PersonMetric: Double] = [:]
        values[.talkShare] = share
        values[.questionsPerHour] = questions
        values[.cutInsPerHour] = cutIns
        values[.wordsPerMinute] = pace
        var people = (1..<max(voices, 1)).map { MeetingFacts.Person(name: "Person \($0)", isOwner: false, values: [.talkShare: 0.2]) }
        if withOwner { people.insert(MeetingFacts.Person(name: owner, isOwner: true, isMain: ownerMain, values: values), at: 0) }
        var f = MeetingFacts(id: id, stamp: 0, start: start.addingTimeInterval(day * 86_400 + 10 * 3600), title: title, series: nil, kind: nil, tags: [],
                             voices: voices, mainVoices: ownerMain ? voices : voices - 1, people: people, values: [:])
        f.hasWordTimes = wordTimes
        return f
    }

    /// `count` meetings spread evenly over the days `from..<to`, with the share that `value` gives for each day.
    private func spread(_ prefix: String, count: Int, from: Double = 0, to: Double = 90, voices: Int = 3, _ value: (Double) -> Double) -> [MeetingFacts] {
        (0..<count).map { i in
            let day = (from + (to - from) * (Double(i) + 0.5) / Double(count)).rounded(.down)
            return meeting("\(prefix)\(i)", day: day, share: value(day), voices: voices)
        }
    }

    private func trends(_ facts: [MeetingFacts], days: Double = 90) -> T { T(facts: facts, interval: period(days), calendar: calendar) }
    private func share(_ t: T, _ split: T.Split = .all) -> T.Series { t.series(.talkShare, split)! }

    private func assertMoved(_ change: T.Change, from: Double, to: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard case .moved(let a, let b) = change else { return XCTFail("\(change)", file: file, line: line) }
        XCTAssertEqual(a, from, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(b, to, accuracy: 0.0001, file: file, line: line)
    }

    /// Numbers that are the same on each run, so a test of chance does not fail by chance.
    private struct Draws {
        var state: UInt64

        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func normal(_ mean: Double, _ spread: Double) -> Double {
            mean + spread * (-2 * log(max(unit(), 1e-12))).squareRoot() * cos(2 * .pi * unit())
        }
    }

    // MARK: Points

    func testEachMeetingOfThePeriodWithAValueIsOnePoint() {
        let t = trends([
            meeting("late", day: 40, share: 0.6, title: "Budget review"),
            meeting("early", day: 3, share: 0.4, cutIns: 2),
            meeting("before", day: -5, share: 0.9),
            meeting("after", day: 95, share: 0.9),
            meeting("no-owner", day: 10, withOwner: false),
            meeting("no-share", day: 12, share: nil, pace: 150),
        ])
        let points = share(t).points
        XCTAssertEqual(points.map(\.id), ["early", "late"], "oldest first, and only the period's meetings with a talk share")
        XCTAssertEqual(points[1].value, 0.6)
        XCTAssertEqual(points[1].title, "Budget review")
        XCTAssertEqual(points[1].date, start.addingTimeInterval(40 * 86_400 + 10 * 3600))
        XCTAssertEqual(t.series(.wordsPerMinute, .all)!.points.map(\.id), ["no-share"])
        XCTAssertEqual(t.series(.cutInsPerHour, .all)!.points.map(\.value), [2], "a call that cannot show a cut-in has no point, not a 0")
        XCTAssertTrue(t.series(.questionsPerHour, .all)!.points.isEmpty)
        XCTAssertEqual(t.series(.all).map(\.metric), [.talkShare, .questionsPerHour, .cutInsPerHour, .wordsPerMinute])
    }

    func testASplitKeepsTheMeetingsOfItsSize() {
        let t = trends([
            meeting("one", day: 1, voices: 2), meeting("three", day: 2, voices: 3), meeting("nine", day: 3, voices: 9),
            meeting("alone", day: 4, voices: 1, pace: 150),
        ])
        XCTAssertEqual(share(t, .all).points.map(\.id), ["one", "three", "nine"], "a talk share of one voice alone is no share of a talk")
        XCTAssertEqual(t.series(.wordsPerMinute, .all)!.points.map(\.id), ["alone"], "its pace is still a pace")
        XCTAssertEqual(share(t, .oneOnOne).points.map(\.id), ["one"])
        XCTAssertEqual(share(t, .group).points.map(\.id), ["three", "nine"])
        XCTAssertEqual(t.splits, [.all, .oneOnOne, .group])
        XCTAssertEqual(trends([meeting("three", day: 2, voices: 3)]).splits, [], "one size only: nothing to split")
    }

    func testAOneOnOneHasTheOwnerAsOneOfItsTwoVoices() {
        // Two others talk and the owner says almost nothing: three people, not a 1:1 of the owner at 1%.
        let quiet = meeting("quiet", day: 1, share: 0.01, voices: 3, ownerMain: false)
        let t = trends([quiet, meeting("one", day: 2, voices: 2)])
        XCTAssertEqual(share(t, .group).points.map(\.id), ["quiet"])
        XCTAssertEqual(share(t, .oneOnOne).points.map(\.id), ["one"])
    }

    func testCutInsNeedWordTimes() {
        // Without word times (a synced copy on the iPhone) a pause inside a line is speech, and more overlaps
        // count as cut-ins than on the Mac: that number is not known, so it has no point.
        let t = trends([meeting("mac", day: 1, cutIns: 2), meeting("phone", day: 2, cutIns: 5, wordTimes: false)])
        XCTAssertEqual(t.series(.cutInsPerHour, .all)!.points.map(\.id), ["mac"])
        XCTAssertEqual(share(t).points.count, 2, "the other numbers do not need word times")
    }

    func testAMetricThatIsNotInTheSectionHasNoSeries() {
        XCTAssertNil(trends([]).series(.longestTurn, .all))
    }

    // MARK: The line

    func testTheLineIsTheMedianOfEachWeek() {
        // Four weeks of five meetings; the last week has one wild meeting.
        var facts: [MeetingFacts] = []
        for week in 0..<4 {
            for i in 0..<5 {
                let wild = week == 3 && i == 4
                facts.append(meeting("w\(week)-\(i)", day: Double(week * 7 + i), share: wild ? 0.95 : 0.40 + Double(week) * 0.05 + Double(i) * 0.01))
            }
        }
        let s = share(trends(facts, days: 28))
        XCTAssertEqual(s.lineDays, 7)
        XCTAssertEqual(s.line.count, 4)
        XCTAssertEqual(s.line.map(\.meetings), [5, 5, 5, 5])
        XCTAssertEqual(s.line[0].value, 0.42, accuracy: 0.0001)
        XCTAssertEqual(s.line[3].value, 0.57, accuracy: 0.0001, "one wild meeting does not move a median")
        XCTAssertEqual(s.line[0].date, start.addingTimeInterval(3.5 * 86_400), "a step sits in the middle of its week")
        XCTAssertEqual(s.line[3].date, start.addingTimeInterval(24.5 * 86_400))
    }

    func testAWeekWithFewerThanThreeMeetingsHasNoStep() {
        var facts: [MeetingFacts] = []
        for week in [0, 1, 3] { for i in 0..<5 { facts.append(meeting("w\(week)-\(i)", day: Double(week * 7 + i))) } }
        facts += [meeting("x1", day: 14), meeting("x2", day: 15)]
        let s = share(trends(facts, days: 28))
        XCTAssertEqual(s.line.map(\.date), [3.5, 10.5, 24.5].map { start.addingTimeInterval($0 * 86_400) })
        XCTAssertEqual(s.line.map(\.segment), [0, 0, 1], "the line breaks where a week has no step")
        XCTAssertEqual(s.points.count, 17, "the meetings are still points")
    }

    func testAThinWeekAmongFullOnesHasNoStep() {
        // Eight meetings in a usual week and three in the week of a holiday: the median of three would stand in
        // the line as if it were a week like the others.
        var facts: [MeetingFacts] = []
        for week in 0..<4 {
            for i in 0..<(week == 2 ? 3 : 8) { facts.append(meeting("w\(week)-\(i)", day: Double(week * 7) + Double(i) * 0.8, share: week == 2 ? 0.9 : 0.5)) }
        }
        let s = share(trends(facts, days: 28))
        XCTAssertEqual(s.lineDays, 7)
        XCTAssertEqual(s.line.map(\.meetings), [8, 8, 8])
        XCTAssertEqual(s.line.map(\.value), [0.5, 0.5, 0.5])
    }

    func testFewMeetingsAWeekGetWiderSteps() {
        // Two a week for 12 weeks: a week's median would be noise, four weeks hold eight.
        let sparse = share(trends(spread("m", count: 24, to: 84) { _ in 0.5 }, days: 84))
        XCTAssertEqual(sparse.lineDays, 28)
        XCTAssertEqual(sparse.line.count, 3)
        XCTAssertEqual(sparse.line.map(\.meetings), [8, 8, 8])
        // A year of five a week: 52 weekly steps would be a scribble.
        let year = share(trends(spread("m", count: 260, to: 364) { _ in 0.5 }, days: 364))
        XCTAssertEqual(year.lineDays, 14)
        XCTAssertEqual(year.line.count, 26)
    }

    func testTheLineStartsAtTheFirstMeeting() {
        // "Year to date" in a library of nine weeks: the empty weeks before the first meeting do not count.
        let facts = (0..<45).map { i in meeting("m\(i)", day: 301 + Double(i / 5) * 7 + Double(i % 5)) }
        let s = share(trends(facts, days: 364))
        XCTAssertEqual(s.lineDays, 7)
        XCTAssertEqual(s.line.count, 9)
        XCTAssertEqual(s.line.map(\.meetings), Array(repeating: 5, count: 9))
    }

    func testAVeryLongPeriodStillHasALine() {
        let facts = (0..<1_000).map { i in meeting("m\(i)", day: Double(i) * 3) }
        let s = share(trends(facts, days: 3_000))
        XCTAssertFalse(s.line.isEmpty)
        XCTAssertLessThanOrEqual(s.line.count, T.maximumSteps)
    }

    func testTheWeeksFollowTheCalendarAcrossAClockChange() {
        // New York moves its clocks on 14 March 2027. A meeting at 23:30 on the evening before a week's first day
        // and one at 00:30 on that day fall in their own weeks, not an hour over.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let first = ny.date(from: DateComponents(year: 2027, month: 2, day: 21))!
        let interval = DateInterval(start: first, end: ny.date(from: DateComponents(year: 2027, month: 3, day: 21))!)
        var facts: [MeetingFacts] = []
        for day in 0..<28 {
            for (n, minute) in [30, 23 * 60 + 30].enumerated() {
                let at = ny.date(byAdding: .minute, value: minute, to: ny.date(byAdding: .day, value: day, to: first)!)!
                var f = meeting("d\(day)-\(n)", day: 0)
                f.start = at
                facts.append(f)
            }
        }
        let s = T(facts: facts, interval: interval, calendar: ny).series(.talkShare, .all)!
        XCTAssertEqual(s.lineDays, 7)
        XCTAssertEqual(s.line.map(\.meetings), [14, 14, 14, 14])
    }

    func testOneWeekHasNoLine() {
        let s = share(trends((0..<6).map { meeting("m\($0)", day: Double($0)) }, days: 7))
        XCTAssertTrue(s.line.isEmpty, "one step is not a line")
        XCTAssertEqual(s.points.count, 6)
    }

    func testThePeriodsLastDayEndsTheLastWeek() {
        // "Last 30 days" ends now, in the middle of a day: the weeks still end with that whole day.
        let interval = DateInterval(start: start, end: start.addingTimeInterval(27 * 86_400 + 15 * 3600))
        let facts = (0..<28).map { meeting("m\($0)", day: Double($0), share: 0.5) }.filter { interval.contains($0.start) }
        let s = T(facts: facts, interval: interval, calendar: calendar).series(.talkShare, .all)!
        XCTAssertEqual(s.line.map(\.meetings), [7, 7, 7, 7])
    }

    func testThePeriodIsCountedInDaysOfTheCalendar() {
        // "The last 90 days" begins at the start of a day 89 days back and ends now: 90 days of the calendar.
        let interval = DateInterval(start: start, end: start.addingTimeInterval(89 * 86_400 + 9 * 3600))
        let facts = spread("m", count: 30) { $0 < 30 ? 0.68 : $0 < 60 ? 0.64 : 0.59 }.filter { interval.contains($0.start) }
        let s = T(facts: facts, interval: interval, calendar: calendar).series(.talkShare, .all)!
        XCTAssertEqual(s.days, 90)
        XCTAssertEqual(s.sentence, "Down from 68% to 59% over 90 days")
        XCTAssertEqual(share(trends([], days: 14)).days, 14)
    }

    // MARK: The usual band

    func testTheUsualBandComesFromTheMeetingsBeforeThePeriod() {
        let before = [0.30, 0.34, 0.38, 0.42, 0.46, 0.50].enumerated().map { meeting("b\($0)", day: -Double($0 + 1), share: $1) }
        let now = (0..<6).map { meeting("n\($0)", day: Double($0), share: 0.8) }
        let band = share(trends(before + now)).usual
        XCTAssertEqual(band?.low, 0.30)
        XCTAssertEqual(band?.high, 0.50)
        XCTAssertEqual(band?.median ?? 0, 0.40, accuracy: 0.0001)
        XCTAssertEqual(band?.meetings, 6)
        XCTAssertEqual(band?.fromBefore, true)
    }

    func testWithLittleBeforeTheBandIsThePeriodsOwn() {
        let before = [0.1, 0.1, 0.1, 0.1].enumerated().map { meeting("b\($0)", day: -Double($0 + 1), share: $1) }
        let now = [0.50, 0.55, 0.60, 0.65, 0.70].enumerated().map { meeting("n\($0)", day: Double($0), share: $1) }
        let band = share(trends(before + now)).usual
        XCTAssertEqual(band?.low, 0.50)
        XCTAssertEqual(band?.high, 0.70)
        XCTAssertEqual(band?.fromBefore, false)
        XCTAssertNil(share(trends(Array(now.prefix(4)))).usual, "four meetings do not say what is usual")
    }

    func testTheBandUsesTheLastFiftyMeetingsBefore() {
        let old = (0..<20).map { meeting("o\($0)", day: -400 - Double($0), share: 0.9) }
        let recent = (0..<50).map { meeting("r\($0)", day: -1 - Double($0), share: 0.4) }
        let band = share(trends(old + recent + [meeting("n", day: 1)])).usual
        XCTAssertEqual(band?.meetings, 50)
        XCTAssertEqual(band?.high, 0.4, "what was usual long ago is not in it")
    }

    func testABandOfASplitComesFromThatSize() {
        let ones = (0..<6).map { meeting("o\($0)", day: -Double($0 + 1), share: 0.6, voices: 2) }
        let groups = (0..<6).map { meeting("g\($0)", day: -Double($0 + 1), share: 0.2, voices: 5) }
        let t = trends(ones + groups + [meeting("n1", day: 1, voices: 2), meeting("n2", day: 2, voices: 5)])
        XCTAssertEqual(share(t, .oneOnOne).usual?.low, 0.6)
        XCTAssertEqual(share(t, .group).usual?.high, 0.2)
        XCTAssertNil(share(t, .all).usual, "a usual range across 1:1s and groups is no one's usual")
        XCTAssertNil(share(t, .all).typical)
    }

    // MARK: The change

    func testAShiftThatHoldsIsSaidWithItsNumbers() {
        // 68% in the first 30 days, 59% in the last 30, ten meetings each.
        let facts = spread("m", count: 30) { $0 < 30 ? 0.68 : $0 < 60 ? 0.64 : 0.59 }
        let s = share(trends(facts))
        XCTAssertEqual(s.change, .moved(from: 0.68, to: 0.59))
        XCTAssertEqual(s.sentence, "Down from 68% to 59% over 90 days")
        XCTAssertEqual(s.typical ?? 0, 0.64, accuracy: 0.0001)
    }

    func testAShiftSmallerThanTheLeastDifferenceIsNoChange() {
        let s = share(trends(spread("m", count: 60) { $0 < 30 ? 0.60 : $0 < 60 ? 0.62 : 0.66 }))
        XCTAssertEqual(s.change, .steady, "six points of talk share is under the eight that matter")
        XCTAssertEqual(s.sentence, "No clear change")
    }

    func testNoiseIsNotATrend() {
        // 45 meetings around 60% with a spread of ten points, 300 times over: a trend may be claimed in a few of
        // them by chance, and in no more.
        var claims = 0
        for seed in 0..<300 {
            var draws = Draws(state: 0x9E37_79B9_7F4A_7C15 &+ UInt64(seed) &* 7919)
            let s = share(trends(spread("m", count: 45) { _ in min(1, max(0, draws.normal(0.6, 0.1))) }))
            if case .moved = s.change { claims += 1 }
        }
        XCTAssertLessThanOrEqual(claims, 6, "\(claims) of 300 steady histories read as a trend")
    }

    func testAShiftInNoiseIsFoundWhenItIsLargeEnough() {
        var found = 0
        for seed in 0..<100 {
            var draws = Draws(state: 0x9E37_79B9_7F4A_7C15 &+ UInt64(seed) &* 104_729)
            // From 70% down to 50% across the period, with a spread of eight points.
            let s = share(trends(spread("m", count: 60) { day in min(1, max(0, draws.normal(0.70 - 0.20 * day / 90, 0.08))) }))
            if case .moved(let from, let to) = s.change {
                XCTAssertGreaterThan(from, to)
                found += 1
            }
        }
        XCTAssertGreaterThanOrEqual(found, 90, "a real fall of twenty points was found in \(found) of 100 histories")
    }

    func testOneWildMeetingIsNotATrend() {
        var facts = spread("m", count: 30) { _ in 0.5 }
        facts.append(meeting("wild", day: 88, share: 1.0))
        XCTAssertEqual(share(trends(facts)).change, .steady)
    }

    func testTooFewMeetingsAtEitherEndSayNothing() {
        // Plenty in the middle, four in the last third.
        let facts = spread("a", count: 10, from: 0, to: 30) { _ in 0.7 } + spread("b", count: 4, from: 60, to: 90) { _ in 0.3 }
        let s = share(trends(facts))
        XCTAssertEqual(s.change, .tooFew)
        XCTAssertEqual(s.sentence, "Too few meetings to show a trend")
        XCTAssertEqual(share(trends([])).change, .tooFew)
    }

    func testAPeriodUnderThreeWeeksHasNoTrend() {
        // The thirds of a week are different weekdays, not different times.
        let s = share(trends(spread("m", count: 30, to: 14) { $0 < 5 ? 0.8 : 0.3 }, days: 14))
        XCTAssertEqual(s.change, .tooShort)
        XCTAssertEqual(s.sentence, "The period is too short to show a trend")
        XCTAssertNotEqual(share(trends(spread("m", count: 30, to: 21) { $0 < 7 ? 0.8 : 0.3 }, days: 21)).change, .tooShort)
    }

    func testAChangeOfMixIsNotAChangeOfTalkShare() {
        // 60% in every 1:1 and 30% in every group; the 1:1s go from a quarter of the meetings to three quarters.
        // The typical meeting of all goes from 30% to 60%, and the owner talks as ever.
        let facts = spread("o1", count: 5, from: 0, to: 30, voices: 2) { _ in 0.60 } + spread("g1", count: 15, from: 0, to: 30, voices: 5) { _ in 0.30 }
            + spread("o2", count: 10, from: 30, to: 60, voices: 2) { _ in 0.60 } + spread("g2", count: 10, from: 30, to: 60, voices: 5) { _ in 0.30 }
            + spread("o3", count: 15, from: 60, to: 90, voices: 2) { _ in 0.60 } + spread("g3", count: 5, from: 60, to: 90, voices: 5) { _ in 0.30 }
        let t = trends(facts)
        XCTAssertEqual(share(t, .all).change, .bySize(oneOnOne: .steady, group: .steady))
        XCTAssertEqual(share(t, .all).sentence, "No clear change")
        XCTAssertFalse(share(t, .all).change.moved)
        XCTAssertEqual(share(t, .oneOnOne).change, .steady)
        XCTAssertEqual(share(t, .group).change, .steady)
        // The chart of all meetings draws one line for each size, which stay flat as the sentence says.
        XCTAssertTrue(share(t, .all).line.isEmpty)
        XCTAssertEqual(share(t, .all).parts.map(\.split), [.oneOnOne, .group])
        XCTAssertEqual(share(t, .all).parts.map(\.line), [share(t, .oneOnOne).line, share(t, .group).line])
        XCTAssertEqual(share(t, .all).parts.map(\.typical), [0.60, 0.30])
        XCTAssertEqual(Set(share(t, .all).parts.flatMap { $0.line.map(\.value) }), [0.60, 0.30])
    }

    func testOneSizeAtEachEndSaysNothing() {
        // 1:1s early and groups late: no size has both ends, so nothing can be compared.
        let facts = spread("o", count: 12, from: 0, to: 30, voices: 2) { _ in 0.60 } + spread("g", count: 12, from: 60, to: 90, voices: 5) { _ in 0.30 }
        let s = share(trends(facts))
        XCTAssertEqual(s.change, .bySize(oneOnOne: .tooFew, group: .tooFew))
        XCTAssertEqual(s.sentence, "Too few meetings of one size to show a trend")
    }

    func testAShiftInBothSizesIsSaidForEach() {
        func half(_ prefix: String, voices: Int, _ high: Double) -> [MeetingFacts] {
            spread(prefix, count: 30, voices: voices) { $0 < 30 ? high : $0 < 60 ? high - 0.06 : high - 0.12 }
        }
        // Sizes far apart, as they are: the typical meeting of all would sit between them and say nothing.
        let t = trends(half("o", voices: 2, 0.70) + half("g", voices: 5, 0.40))
        XCTAssertEqual(share(t, .all).sentence, "Down over 90 days: 1:1s from 70% to 58%, groups from 40% to 28%")
        XCTAssertTrue(share(t, .all).change.moved)
        assertMoved(share(t, .oneOnOne).change, from: 0.70, to: 0.58)
        XCTAssertEqual(share(t, .group).sentence, "Down from 40% to 28% over 90 days")
    }

    func testAShiftInOneSizeNamesTheSize() {
        let ones = spread("o", count: 30, voices: 2) { $0 < 30 ? 0.70 : $0 < 60 ? 0.64 : 0.58 }
        let t = trends(ones + spread("g", count: 30, voices: 5) { _ in 0.30 })
        XCTAssertEqual(share(t, .all).sentence, "Down in 1:1s from 70% to 58% over 90 days; no clear change in groups")
        let few = trends(ones + spread("g", count: 3, voices: 5) { _ in 0.30 })
        XCTAssertEqual(share(few, .all).sentence, "Down in 1:1s from 70% to 58% over 90 days")
        let rising = trends(ones + spread("g", count: 30, voices: 5) { $0 < 30 ? 0.20 : $0 < 60 ? 0.26 : 0.32 })
        XCTAssertEqual(share(rising, .all).sentence, "Down in 1:1s from 70% to 58%, up in groups from 20% to 32% over 90 days")
    }

    func testCutInsOfBothSizesReadWithOneUnit() {
        let facts = (0..<60).map { i -> MeetingFacts in
            let part = i / 20, rate: Double = part == 0 ? 1 : part == 1 ? 2 : 4
            return meeting("m\(i)", day: Double(i) * 1.5, share: nil, voices: i % 2 == 0 ? 2 : 5, cutIns: i % 2 == 0 ? rate : rate + 2)
        }
        XCTAssertEqual(trends(facts).series(.cutInsPerHour, .all)!.sentence, "Up over 90 days: 1:1s from 1.0 to 4.0, groups from 3.0 to 6.0 an hour")
    }

    func testAPaceIsComparedOverAllSizes() {
        // A pace is a pace in any size: only the numbers that follow the size are compared apart.
        let facts = (0..<30).map { i -> MeetingFacts in
            let pace: Double = i < 10 ? 170 : i < 20 ? 160 : 140
            return meeting("m\(i)", day: Double(i * 3), share: nil, voices: i < 15 ? 2 : 5, pace: pace)
        }
        XCTAssertEqual(trends(facts).series(.wordsPerMinute, .all)!.change, .moved(from: 170, to: 140))
    }

    // MARK: Words

    func testEachNumberReadsInItsOwnUnit() {
        let facts = (0..<30).map { i -> MeetingFacts in
            let questions: Double = i < 10 ? 3 : i < 20 ? 5 : 8.5
            let pace: Double = i < 10 ? 172 : i < 20 ? 160 : 148
            return meeting("m\(i)", day: Double(i * 3), share: 0.4, questions: questions, cutIns: 1.26, pace: pace)
        }
        let t = trends(facts)
        XCTAssertEqual(t.series(.questionsPerHour, .all)!.sentence, "Up from 3.0 to 8.5 an hour over 90 days")
        XCTAssertEqual(t.series(.wordsPerMinute, .all)!.sentence, "Down from 172 to 148 words a minute over 90 days")
        XCTAssertEqual(t.series(.cutInsPerHour, .all)!.sentence, "No clear change")
        XCTAssertEqual(T.title(.talkShare), "Talk share")
        XCTAssertEqual(T.title(.questionsPerHour), "Questions you ask")
        XCTAssertEqual(T.title(.cutInsPerHour), "You cut in")
        XCTAssertEqual(T.title(.wordsPerMinute), "Pace")
        XCTAssertEqual(T.text(.talkShare, 0.416), "42%")
        XCTAssertEqual(T.text(.cutInsPerHour, 1.26), "1.3 an hour")
        XCTAssertEqual(T.text(.wordsPerMinute, 151.6), "152 words a minute")
        XCTAssertEqual(T.short(.questionsPerHour, 4), "4.0")
    }

    func testALongPeriodReadsInMonths() {
        let facts = spread("m", count: 120, to: 365) { $0 < 122 ? 0.68 : $0 < 243 ? 0.64 : 0.59 }
        XCTAssertEqual(share(trends(facts, days: 365)).sentence, "Down from 68% to 59% over 12 months")
    }

    func testTheSpokenLineSaysTheSentenceAndTheNumbers() {
        let before = (0..<6).map { meeting("b\($0)", day: -Double($0 + 1), share: 0.5 + Double($0) * 0.04) }
        let s = share(trends(before + spread("m", count: 30) { $0 < 30 ? 0.68 : $0 < 60 ? 0.64 : 0.59 }))
        XCTAssertEqual(s.spoken, "Talk share. Down from 68% to 59% over 90 days. Typical meeting 64%, in 30 meetings. Usual before this period 50 to 70%. " + s.basis)
        XCTAssertEqual(share(trends([])).spoken, "Talk share. No meetings with this number in the period.")
    }

    // MARK: The scale

    func testTheScaleHoldsThePointsTheBandAndTheLine() {
        let before = (0..<6).map { meeting("b\($0)", day: -Double($0 + 1), share: 0.30 + Double($0) * 0.02) }
        let s = share(trends(before + spread("m", count: 30) { _ in 0.62 }))
        XCTAssertLessThanOrEqual(s.scale.lower, 0.30)
        XCTAssertGreaterThanOrEqual(s.scale.upper, 0.62)
        XCTAssertGreaterThanOrEqual(s.scale.lower, 0)
        XCTAssertLessThanOrEqual(s.scale.upper, 1)
        XCTAssertEqual(s.scale.step, 0.1, accuracy: 0.0001)
        XCTAssertEqual(s.scale.lower, 0.3, accuracy: 0.0001)
        XCTAssertEqual(s.scale.upper, 0.7, accuracy: 0.0001)
        XCTAssertEqual(s.scale.marks, [0.3, 0.4, 0.5, 0.6, 0.7])
    }

    func testCountsStartAtZeroAndAPaceDoesNot() {
        let facts = (0..<30).map { i -> MeetingFacts in
            let part = Double(i % 5)
            return meeting("m\(i)", day: Double(i * 3), questions: 4 + part, pace: 140 + part * 10)
        }
        let t = trends(facts)
        XCTAssertEqual(t.series(.questionsPerHour, .all)!.scale.lower, 0)
        XCTAssertEqual(t.series(.questionsPerHour, .all)!.scale.upper, 8)
        XCTAssertEqual(t.series(.wordsPerMinute, .all)!.scale.lower, 140)
        XCTAssertEqual(t.series(.wordsPerMinute, .all)!.scale.upper, 180)
    }

    func testOneFarMeetingDoesNotFlattenTheRest() {
        var facts = (0..<40).map { i -> MeetingFacts in meeting("m\(i)", day: Double(i * 2), questions: Double(3 + i % 4)) }
        facts.append(meeting("burst", day: 50, questions: 60))
        let s = trends(facts).series(.questionsPerHour, .all)!
        XCTAssertLessThan(s.scale.upper, 20, "the chart draws the far meeting at its edge")
        XCTAssertEqual(s.points.count, 41, "and the meeting is still a point")
    }

    func testAShareScaleStaysInsideTheWhole() {
        let facts = (0..<30).map { i -> MeetingFacts in meeting("m\(i)", day: Double(i * 3), share: i % 2 == 0 ? 0.02 : 0.99) }
        let s = share(trends(facts))
        XCTAssertEqual(s.scale.lower, 0)
        XCTAssertEqual(s.scale.upper, 1)
    }

    func testNoPointsGiveAnEmptySeriesWithAScale() {
        let s = share(trends([]))
        XCTAssertTrue(s.points.isEmpty)
        XCTAssertNil(s.typical)
        XCTAssertNil(s.usual)
        XCTAssertLessThan(s.scale.lower, s.scale.upper)
    }

    // MARK: The small-sample factor

    func testTheSmallSampleFactorIsUnchanged() {
        // The table moved to a function that the trend also reads.
        XCTAssertEqual(MeetingAnalytics.Usual([1, 2, 3, 4, 5])!.smallSample, 2.776 / 1.96 * (1.2).squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(MeetingAnalytics.Usual([1, 2, 3])!.smallSample, 3.182 / 1.96 * (1 + 1.0 / 3).squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(MeetingAnalytics.Usual.student(60), 2.0)
        XCTAssertEqual(MeetingAnalytics.Usual.student(18), 2.131)
    }
}
