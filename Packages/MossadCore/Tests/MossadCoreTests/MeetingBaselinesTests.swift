import XCTest
@testable import MossadCore

/// One call against what is normal in the owner's earlier meetings.
final class MeetingBaselinesTests: XCTestCase {
    private typealias A = MeetingAnalytics
    private typealias Line = (key: String, start: Double, end: Double, text: String)

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let owner = "Dana Lee"
    private let sam = "Sam Carter"

    // MARK: Helpers

    private func call(id: String = "now", minutes: Double = 30, names: [String: String] = ["me:A": "Dana Lee", "them:A": "Sam Carter"],
                      title: String? = "Weekly sync", _ lines: [Line]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.speakerNames = names
        r.calendarTitle = title
        r.summary = "A summary."
        r.utterances = lines.map { l in
            let parts = l.key.split(separator: ":")
            return Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: l.start, end: l.end, text: l.text)
        }
        return r
    }

    /// An earlier meeting as facts. `shares` gives each named person's talk share; `person` gives everyone (or
    /// only `onlyFor`) more numbers.
    private func past(_ id: String, daysAgo: Double, title: String? = "Weekly sync", voices: Int? = nil, kind: String? = nil, tags: [String] = [],
                      shares: [(String, Double)], person: [PersonMetric: Double] = [:], onlyFor: String? = nil,
                      meeting: [MeetingMetric: Double] = [:]) -> MeetingFacts {
        MeetingFacts(id: id, stamp: 0, start: start.addingTimeInterval(-daysAgo * 86_400), title: title ?? "Meet call",
                     series: title.map(PeopleDuplicates.normalized), kind: kind, tags: tags, voices: voices ?? shares.count,
                     people: shares.map { name, share in
                         let extra = onlyFor == nil || onlyFor == name ? person : [:]
                         return MeetingFacts.Person(name: name, isOwner: name == owner, values: extra.merging([.talkShare: share]) { _, new in new })
                     },
                     values: meeting)
    }

    /// Dana talks `dana` seconds and Sam the rest of 100 s.
    private func oneOnOne(dana: Double, title: String? = "Dana / Sam") -> CallRecord {
        call(title: title, [("me:A", 0, dana, "My part."), ("them:A", dana, 100, "The other part.")])
    }

    /// Six earlier 1:1s with Sam, each under its own title, where Dana talks about 65%.
    private func oneOnOnes(person: [PersonMetric: Double] = [:], onlyFor: String? = nil, meeting: [MeetingMetric: Double] = [:]) -> [MeetingFacts] {
        [0.67, 0.65, 0.64, 0.66, 0.63, 0.65].enumerated().map { i, share in
            past("o\(i)", daysAgo: Double(i + 1) * 7, title: "Catch up \(i)", shares: [(owner, share), (sam, 1 - share)], person: person, onlyFor: onlyFor,
                 meeting: meeting)
        }
    }

    private func analytics(_ r: CallRecord, _ history: [MeetingFacts], value: (String) -> MeetingValue.Rating? = { _ in nil }) -> A {
        A(record: r, owner: owner, history: history, value: value)
    }

    /// Numbers that are the same on each run, so a test of chance does not fail by chance.
    private struct Draws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        /// A draw from a normal distribution.
        mutating func normal(_ mean: Double, _ spread: Double) -> Double {
            mean + spread * (-2 * log(max(unit(), 1e-12))).squareRoot() * cos(2 * .pi * unit())
        }
    }

    // MARK: The usual range

    func testTheRangeIsTheWholeHistoryUntilTenValuesThenItsMiddle() {
        XCTAssertNil(A.Usual([0.3, 0.4]), "two meetings give no range")
        let few = A.Usual([0.50, 0.30, 0.35, 0.40, 0.10, 0.36])!
        XCTAssertEqual(few.samples, 6)
        XCTAssertEqual(few.low, 0.10)
        XCTAssertEqual(few.high, 0.50)
        XCTAssertEqual(few.median, 0.355, accuracy: 0.0001)
        XCTAssertTrue(few.isFirm)
        XCTAssertFalse(A.Usual([10, 20, 30])!.isFirm, "three meetings give a range, and no judgment")
        let many = A.Usual((0...10).map(Double.init))!
        XCTAssertEqual(many.low, 1, accuracy: 0.0001, "the 10th percentile")
        XCTAssertEqual(many.high, 9, accuracy: 0.0001, "the 90th percentile")
    }

    func testAValueStandsOutOnlyFarOutsideAFirmHistory() {
        let history = [0.30, 0.32, 0.35, 0.38, 0.40, 0.34]
        func reading(_ v: Double) -> A.Reading { A.Reading(value: v, history: history, metric: PersonMetric.talkShare) }
        XCTAssertEqual(reading(0.36).standing, .usual)
        XCTAssertEqual(reading(0.42).standing, .usual, "a little over the range is not news")
        XCTAssertEqual(reading(0.46).standing, .usual, "eight points from the median, but not far in spreads")
        XCTAssertEqual(reading(0.46).score, 0)
        XCTAssertEqual(reading(0.60).standing, .above)
        XCTAssertEqual(reading(0.10).standing, .below)
        XCTAssertGreaterThanOrEqual(reading(0.60).score, A.Reading.minimumScore)
        XCTAssertGreaterThan(reading(0.70).score, reading(0.60).score)
    }

    func testFewerThanFiveValuesGiveARangeAndNoMark() {
        let four = A.Reading(value: 0.9, history: [0.30, 0.31, 0.32, 0.33], metric: PersonMetric.talkShare)
        XCTAssertNotNil(four.usual)
        XCTAssertNil(four.standing, "not above, and not called usual either")
        XCTAssertFalse(four.stoodOut)
        let two = A.Reading(value: 0.9, history: [0.3, 0.3], metric: PersonMetric.talkShare)
        XCTAssertNil(two.usual)
        XCTAssertNil(two.standing)
        let context = A.Context(kind: .oneOnOne, meetings: 4, label: "in 1:1s with you")
        XCTAssertEqual(MeetingFindings.usually(.talkShare, four.usual!, context: context), "30 to 33% in 1:1s with you, in 4 meetings so far",
                       "and the words do not say usually")
    }

    func testAHistoryOfEqualValuesNeedsTheLeastDifferenceThatMatters() {
        let same = [Double](repeating: 150, count: 8)
        XCTAssertEqual(A.Reading(value: 165, history: same, metric: PersonMetric.wordsPerMinute).standing, .usual, "15 words a minute is under the 20 that matter")
        XCTAssertEqual(A.Reading(value: 175, history: same, metric: PersonMetric.wordsPerMinute).standing, .usual, "25 is over it, but one step is not far")
        XCTAssertEqual(A.Reading(value: 200, history: same, metric: PersonMetric.wordsPerMinute).standing, .above)
    }

    /// The rule of the review: an ordinary value must rarely get a mark. Each number is drawn from the same
    /// distribution as its history, with a spread that is ordinary for it.
    func testOrdinaryValuesRarelyStandOut() {
        let cases: [(name: String, mean: Double, spread: Double, mark: ([Double], Double) -> Bool)] = [
            ("talk share", 0.35, 0.06, { A.Reading(value: $1, history: $0, metric: PersonMetric.talkShare).stoodOut }),
            ("talk share, wide", 0.35, 0.10, { A.Reading(value: $1, history: $0, metric: PersonMetric.talkShare).stoodOut }),
            ("words a minute", 155, 14, { A.Reading(value: $1, history: $0, metric: PersonMetric.wordsPerMinute).stoodOut }),
            ("fillers a minute", 2.5, 0.8, { A.Reading(value: $1, history: $0, metric: PersonMetric.fillersPerMinute).stoodOut }),
            ("length", 1800, 300, { A.Reading(value: $1, history: $0, metric: MeetingMetric.length).stoodOut }),
        ]
        var draws = Draws()
        for c in cases {
            for n in [5, 7, 10, 20, 30] {
                var marked = 0
                let runs = 4000
                for _ in 0..<runs {
                    let history = (0..<n).map { _ in draws.normal(c.mean, c.spread) }
                    if c.mark(history, draws.normal(c.mean, c.spread)) { marked += 1 }
                }
                XCTAssertLessThan(Double(marked) / Double(runs), 0.03, "\(c.name) with \(n) earlier meetings: \(marked) of \(runs) ordinary values got a mark")
            }
        }
    }

    func testAValueFarFromItsHistoryStillStandsOut() {
        var draws = Draws()
        for n in [5, 10, 30] {
            var marked = 0
            for _ in 0..<1000 {
                let history = (0..<n).map { _ in draws.normal(0.35, 0.05) }
                if A.Reading(value: 0.62, history: history, metric: PersonMetric.talkShare).stoodOut { marked += 1 }
            }
            XCTAssertGreaterThan(marked, n == 5 ? 600 : 900, "62% against a usual 35% with \(n) earlier meetings")
        }
    }

    // MARK: Contexts

    func testTheSeriesComesFirst() {
        let history = (1...5).map { past("s\($0)", daysAgo: Double($0 * 7), shares: [(owner, 0.5), (sam, 0.5)]) }
            + [past("x1", daysAgo: 2, title: "Planning", shares: [(owner, 0.9), (sam, 0.1)])]
        let b = analytics(oneOnOne(dana: 50, title: "Weekly sync"), history).baselines
        XCTAssertEqual(b.earlier, 6)
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .series, meetings: 5, label: "in Weekly sync"))
        XCTAssertEqual(b.person("me:A")?.context?.kind, .series)
        XCTAssertEqual(b.meeting.context, .init(kind: .series, meetings: 5, label: "in Weekly sync"))
        XCTAssertEqual(b.person("them:A")?[.talkShare]?.usual?.samples, 5)
    }

    func testAOneOnOneIsComparedWithTheOtherOneOnOnesWithThatPerson() {
        let others = [
            past("g1", daysAgo: 3, title: "Team", shares: [(owner, 0.2), (sam, 0.2), ("Jo Park", 0.6)]),
            past("j1", daysAgo: 4, title: "Dana / Jo", shares: [(owner, 0.5), ("Jo Park", 0.5)]),
        ]
        let a = analytics(oneOnOne(dana: 40), oneOnOnes() + others)
        let him = a.baselines.person("them:A")!, dana = a.baselines.person("me:A")!
        XCTAssertEqual(him.context, .init(kind: .oneOnOne, meetings: 6, label: "in 1:1s with you"))
        XCTAssertEqual(dana.context, .init(kind: .oneOnOne, meetings: 6, label: "in your 1:1s with Sam"))
        XCTAssertEqual(him[.talkShare]?.value, 0.6)
        XCTAssertEqual(him[.talkShare]?.standing, .above)
        XCTAssertEqual(MeetingFindings.usually(.talkShare, him[.talkShare]!.usual!, context: him.context!), "usually 33 to 37% in 1:1s with you")
        XCTAssertEqual(him.shareTrend.count, 7)
        XCTAssertEqual(him.shareTrend.last, 0.6, "oldest first, this call last")
        XCTAssertEqual(a.baselines.meeting.context?.label, "in your 1:1s with Sam")
        XCTAssertEqual(a.baselines.ownerWith, [], "in a 1:1 the owner's own row says it")
        XCTAssertEqual(a.baselines.standouts.map(\.id), ["me:A.talkShare"], "said one time, about the owner")
        XCTAssertEqual(a.baselines.standouts.first?.text, "talked 40% of the time; usually 63 to 67% in your 1:1s with Sam")
    }

    func testAFirstOneOnOneWithSomeoneIsComparedWithTheOwnersOtherOneOnOnes() {
        // No 1:1 with Sam yet: three with other people, where Dana talks 60% and they 40%.
        let own = ["Jo Park", "Riley Chen", "Casey Brooks", "Jo Park", "Riley Chen"].enumerated().map { i, name in
            past("p\(i)", daysAgo: Double(i + 1), title: "With \(i)", shares: [(owner, 0.6), (name, 0.4)])
        }
        let groups = (1...10).map { past("g\($0)", daysAgo: Double(10 + $0), title: "Team \($0)", shares: [(owner, 0.2), (sam, 0.2), ("A", 0.2), ("B", 0.2), ("C", 0.2)]) }
        let b = analytics(oneOnOne(dana: 60), own + groups).baselines
        XCTAssertEqual(b.person("me:A")?.context, .init(kind: .ownOneOnOnes, meetings: 5, label: "in your 1:1s"))
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .ownOneOnOnes, meetings: 5, label: "for the other person in your 1:1s"))
        XCTAssertEqual(b.person("them:A")?[.talkShare]?.usual?.median, 0.4, "the people who sat across from Dana, not Sam in groups")
        XCTAssertEqual(b.person("them:A")?.shareTrend, [], "their shares are not Sam's history")
        XCTAssertEqual(b.meeting.context, .init(kind: .ownOneOnOnes, meetings: 5, label: "in your 1:1s"))
        XCTAssertEqual(b.standouts, [])
    }

    func testAOneOnOneIsNeverMeasuredAgainstGroupsBySize() {
        // The review's case: ten meetings of five people, then a first 1:1.
        let groups = (1...10).map { past("g\($0)", daysAgo: Double($0), title: "Team \($0)", shares: [(owner, 0.2), (sam, 0.2), ("A", 0.2), ("B", 0.2), ("C", 0.2)],
                                         person: [.wordsPerMinute: 150], meeting: [.voices: 5, .length: 1800]) }
        let b = analytics(oneOnOne(dana: 50), groups).baselines
        let dana = b.person("me:A")!
        XCTAssertEqual(dana.context, .init(kind: .person, meetings: 10, label: "in all 10 meetings with Sam"))
        XCTAssertEqual(b.person("them:A")?.context?.label, "in all 10 meetings with you")
        XCTAssertNil(dana[.talkShare], "half of a talk between two is not more than a fifth of a talk between five")
        XCTAssertNil(dana[.cutInsPerHour])
        XCTAssertEqual(dana.shareTrend, [])
        XCTAssertNotNil(dana[.averageTurn], "a number that does not follow the size is still compared")
        XCTAssertNil(b.meeting[.voices], "and 2 people is not fewer than usual")
        XCTAssertNotNil(b.meeting[.length])
        XCTAssertEqual(b.standouts.filter { $0.id.contains("talkShare") || $0.id.contains("voices") }, [])
    }

    func testAGroupIsComparedWithMeetingsOfItsSizeAndKind() {
        let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        var r = call(names: trio, title: "Roadmap", [("me:A", 0, 30, "A."), ("them:A", 30, 60, "B."), ("them:B", 60, 100, "C.")])
        r.kind = "Monthly update"
        r.tags = ["Budget"]
        func group(_ id: String, _ days: Double, kind: String? = nil, tags: [String] = [], voices: Int = 3) -> MeetingFacts {
            past(id, daysAgo: days, title: "Other \(id)", voices: voices, kind: kind, tags: tags, shares: [(owner, 0.3), (sam, 0.3)], meeting: [.voices: Double(voices)])
        }
        let sameKind = [group("k1", 1, kind: "monthly update"), group("k2", 2, kind: "Monthly update"), group("k3", 3, kind: "Monthly update")]
        let sameTopic = [group("t1", 4, tags: ["budget"]), group("t2", 5, tags: ["Budget", "Hiring"]), group("t3", 6, tags: ["Budget"])]
        let sameSize = [group("z1", 7), group("z2", 8, voices: 4), group("z3", 9)]
        let large = [group("l1", 10, voices: 9), group("l2", 11, voices: 9), group("l3", 12, voices: 9)]

        var b = analytics(r, sameKind + sameTopic + sameSize + large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .setting, meetings: 3, label: "in monthly update meetings of 3 to 4 people"))
        b = analytics(r, sameTopic + sameSize + large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .setting, meetings: 3, label: "in meetings of 3 to 4 people about Budget"))
        b = analytics(r, sameSize + large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .setting, meetings: 3, label: "in meetings of 3 to 4 people"))
        XCTAssertEqual(b.meeting.context?.label, "in meetings of 3 to 4 people")
        XCTAssertNil(b.meeting[.voices], "a meeting of 3 to 4 people among meetings of 3 to 4 people says nothing")
        XCTAssertNotNil(b.person("them:A")?[.talkShare], "meetings of one size compare a share")
        b = analytics(r, large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .person, meetings: 3, label: "in all 3 meetings with you"))
        XCTAssertEqual(b.person("me:A")?.context, .init(kind: .person, meetings: 3, label: "in all 3 of your meetings"))
        XCTAssertNil(b.person("them:A")?[.talkShare], "meetings of nine people do not say what a share among three is")
        XCTAssertEqual(b.meeting.context, .init(kind: .recent, meetings: 3, label: "in your last 3 meetings"))
        XCTAssertNil(b.person("them:B")?.context, "Jo was in none of them: not enough history yet")
        XCTAssertEqual(b.person("them:B")?.readings, [:])
        XCTAssertTrue(b.hasHistory)
        XCTAssertFalse(b.hasFirmHistory, "three meetings are a range, and no judgment")
    }

    func testOnlyEarlierMeetingsAreHistory() {
        let r = oneOnOne(dana: 50)
        let later = (1...6).map { past("l\($0)", daysAgo: -Double($0), title: "Dana / Sam", shares: [(owner, 0.5), (sam, 0.5)]) }
        var itself = MeetingFacts(record: r, owner: owner)
        itself.start = start.addingTimeInterval(-60)
        let b = analytics(r, later + [itself]).baselines
        XCTAssertEqual(b.earlier, 0)
        XCTAssertFalse(b.hasHistory)
        XCTAssertNil(b.person("me:A")?.context)
        XCTAssertNil(b.meeting.context)
        XCTAssertEqual(b.standouts, [])
        XCTAssertNil(b.trends)
    }

    func testTheOwnersShareIsComparedForEachOtherPersonOfAGroupInMeetingsOfThatSize() {
        let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        let r = call(names: trio, title: nil, [("me:A", 0, 70, "A."), ("them:A", 70, 85, "B."), ("them:B", 85, 100, "C.")])
        let withSam = (1...6).map { past("s\($0)", daysAgo: Double($0), title: "Other \($0)", voices: 3, shares: [(owner, 0.40 + Double($0) / 100), (sam, 0.3)]) }
        let withJo = (1...6).map { past("j\($0)", daysAgo: Double($0), title: "Jo \($0)", voices: 6, shares: [(owner, 0.2), ("Jo Park", 0.3)]) }
        let a = analytics(r, withSam + withJo)
        XCTAssertEqual(a.baselines.ownerWith.map(\.id), ["them:A"], "the six meetings with Jo had six people: they say nothing about a share among three")
        let w = a.baselines.ownerWith[0]
        XCTAssertEqual(w.context, .init(kind: .setting, meetings: 6, label: "in meetings of 3 to 4 people with Sam"))
        XCTAssertEqual(w.reading.value, 0.7)
        XCTAssertEqual(w.reading.standing, .above)
        // The owner's share stood out overall and with Sam: one cause, so one line about it.
        let shareLines = a.baselines.standouts.filter { $0.id == "with.them:A" || $0.id == "me:A.talkShare" }
        XCTAssertEqual(shareLines.count, 1, "\(shareLines.map(\.id))")
        XCTAssertEqual(shareLines.first?.subject, "me:A")
        let text = MeetingFindings.did(.talkShare, w.reading.value, you: true) + "; usually 41 to 46% in meetings of 3 to 4 people with Sam"
        XCTAssertEqual(text, "talked 70% of the time; usually 41 to 46% in meetings of 3 to 4 people with Sam")
    }

    // MARK: The meeting

    func testTheMeetingIsComparedWithItsSeriesAndTheCoachsRatings() {
        var r = call(minutes: 60, [("me:A", 0, 50, "A."), ("them:A", 50, 100, "B.")])
        r.decisions = [Decision(text: "One", at: 40), Decision(text: "Two", at: 20), Decision(text: "Three"), Decision(text: "Four")]
        let history = (1...6).map {
            past("s\($0)", daysAgo: Double($0 * 7), shares: [(owner, 0.5), (sam, 0.5)],
                 meeting: [.length: 1500 + Double($0) * 60, .decisions: 0, .voices: 2, .actionItems: 6])
        }
        let ratings: [String: MeetingValue.Rating] = ["s1": .high, "s2": .high, "s3": .high, "s4": .high, "s5": .high]
        let review = CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil,
                                 value: MeetingValue(rating: .low, reason: "", action: .shorten, suggestion: ""))
        let a = A(record: r, owner: owner, review: review, history: history, value: { ratings[$0] })
        let m = a.baselines.meeting
        XCTAssertEqual(m[.length]?.value, 3600)
        XCTAssertEqual(m[.length]?.standing, .above)
        XCTAssertEqual(m[.decisions]?.standing, .above)
        XCTAssertEqual(m[.voices]?.standing, .usual)
        XCTAssertEqual(m[.actionItems]?.standing, .below)
        XCTAssertEqual(m[.value]?.value, 1)
        XCTAssertEqual(m[.value]?.usual?.samples, 5, "only the rated meetings")
        XCTAssertEqual(m[.value]?.standing, .below)
        XCTAssertNil(m[.screens], "nothing was captured in any of them")
        XCTAssertEqual(a.facts.values[.value], 1)
        let texts = Dictionary(uniqueKeysWithValues: a.baselines.standouts.map { ($0.id, $0) })
        XCTAssertEqual(texts["meeting.length"]?.text, "The meeting ran 1 h; usually 26 to 31 min in Weekly sync")
        XCTAssertNil(texts["meeting.length"]?.evidence)
        XCTAssertEqual(texts["meeting.decisions"]?.text, "4 decisions; usually 0 in Weekly sync")
        XCTAssertEqual(texts["meeting.decisions"]?.evidence, .moment(20), "the first decision")
        XCTAssertEqual(texts["meeting.value"]?.text, "The coach rated it low; usually high in Weekly sync")
        XCTAssertEqual(texts["meeting.actionItems"]?.text, "No action items; usually 6 in Weekly sync")
    }

    func testAValueTheCallDoesNotHaveIsNotCompared() {
        // No summary: no decisions or action items to count. No capture: no screens.
        var r = call(minutes: 30, [("me:A", 0, 50, "A."), ("them:A", 50, 100, "B.")])
        r.summary = nil
        let history = (1...6).map { past("s\($0)", daysAgo: Double($0 * 7), shares: [(owner, 0.5), (sam, 0.5)], meeting: [.decisions: 3, .actionItems: 5, .screens: 4]) }
        let a = analytics(r, history)
        XCTAssertNil(a.facts.values[.decisions])
        XCTAssertNil(a.facts.values[.actionItems])
        XCTAssertNil(a.facts.values[.screens])
        XCTAssertNil(a.baselines.meeting[.decisions], "not \"no decisions; usually 3\"")
        XCTAssertNil(a.baselines.meeting[.screens])
        XCTAssertEqual(a.baselines.standouts, [])
        // And a meeting of the history without the value is not a 0 in the range.
        r.summary = "Now it has one."
        let mixed = history.prefix(3) + (4...9).map { past("n\($0)", daysAgo: Double($0 * 7), shares: [(owner, 0.5), (sam, 0.5)]) }
        XCTAssertEqual(analytics(r, Array(mixed)).baselines.meeting[.decisions]?.usual?.samples, 3)
    }

    func testTheScheduleSaysWhenTheOwnerJoinedAndHowLongTheRecordingRan() {
        var r = oneOnOne(dana: 50)
        XCTAssertNil(analytics(r, []).baselines.schedule, "no invite")
        r.plannedStart = start.addingTimeInterval(-6 * 60)
        r.plannedEnd = start.addingTimeInterval(18 * 60)
        let s = analytics(r, []).baselines.schedule!
        XCTAssertEqual(s.startDelay, 360)
        XCTAssertEqual(s.overrun, 720)
        XCTAssertEqual(s.plannedLength, 1440)
        XCTAssertTrue(s.joinedLate)
        XCTAssertTrue(s.ranOver)
        XCTAssertEqual(MeetingFindings.joined(s), "you joined 6 min after the planned start", "the recording begins when the owner joins")
        XCTAssertEqual(MeetingFindings.ended(s), "the recording ran 12 min past the planned end")
        XCTAssertEqual(analytics(r, []).baselines.standouts, [], "a late join is not measured against anything, so it is not what stood out")

        r.plannedStart = start.addingTimeInterval(30)
        r.plannedEnd = r.end.addingTimeInterval(120)
        let quiet = analytics(r, []).baselines.schedule!
        XCTAssertFalse(quiet.joinedLate)
        XCTAssertFalse(quiet.ranOver)
        XCTAssertEqual(MeetingFindings.joined(quiet), "you joined on time")
        XCTAssertEqual(MeetingFindings.ended(quiet), "the recording ended 2 min before the planned end")
    }

    // MARK: Trends

    func testTheTrendsFollowTheSeriesWithThisCallLast() {
        let r = oneOnOne(dana: 40, title: "Weekly sync")
        let both: [(String, Double)] = [(owner, 0.5), (sam, 0.5)], onlySam: [(String, Double)] = [(sam, 1)]
        let history = (1...14).map { i -> MeetingFacts in
            past("s\(i)", daysAgo: Double(i * 7), voices: 2, shares: i == 2 ? onlySam : both, meeting: [.length: 1800 + Double(i)])
        }
        let ratings: [String: MeetingValue.Rating] = ["s1": .high, "s3": .low]
        let review = CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil,
                                 value: MeetingValue(rating: .medium, reason: "", action: .keep, suggestion: ""))
        let t = A(record: r, owner: owner, review: review, history: history, value: { ratings[$0] }).baselines.trends!
        XCTAssertEqual(t.context.kind, .series)
        XCTAssertEqual(t.length.last?.id, "now")
        XCTAssertEqual(t.length.map(\.id).first, "s12", "oldest first; the meeting with no voice of Dana's was not a 1:1 and is not in a 1:1's series")
        XCTAssertEqual(t.talkShare.map(\.value).suffix(3), [0.5, 0.5, 0.4])
        XCTAssertFalse(t.talkShare.contains { $0.id == "s2" }, "no voice of the owner's is no point, not 0%")
        XCTAssertEqual(t.value.map(\.value), [1, 3, 2], "only the rated meetings")
        XCTAssertEqual(t.value.map(\.id), ["s3", "s1", "now"])
    }

    func testATrendNeedsThreePoints() {
        let r = oneOnOne(dana: 40)
        let one = [past("s1", daysAgo: 7, title: "Dana / Sam", shares: [(owner, 0.5), (sam, 0.5)], meeting: [.length: 1800])]
        XCTAssertNil(analytics(r, one).baselines.trends)
        // Not the series, but 1:1s with Sam.
        let two = one + [past("o1", daysAgo: 9, title: "Catch up", shares: [(owner, 0.5), (sam, 0.5)], meeting: [.length: 1800])]
        let t = analytics(r, two).baselines.trends
        XCTAssertEqual(t?.context, .init(kind: .oneOnOne, meetings: 2, label: "in your 1:1s with Sam"))
        XCTAssertEqual(t?.length.count, 3)
        XCTAssertEqual(t?.value, [], "no ratings, no line")
        XCTAssertEqual(analytics(r, two).baselines.person("me:A")?.shareTrend, [], "and two meetings are not a context")
    }

    // MARK: What stood out

    func testWhatStoodOutRanksTheNumbersFurthestFromUsual() {
        // Half an hour. Dana talks 25 s of 96 s; Sam cuts in twice and asks in three lines.
        let r = call(minutes: 30, title: "Dana / Sam", [
            ("me:A", 0, 20, "So the plan is this."),
            ("them:A", 15, 40, "Wait, why that date? Who agreed?"),
            ("them:A", 41, 60, "And who pays for it?"),
            ("me:A", 70, 75, "We do."),
            ("them:A", 73, 100, "No, that is not right at all, is it?"),
        ])
        let a = analytics(r, oneOnOnes(person: [.questionsPerHour: 0, .cutInsPerHour: 0, .cutOffsPerHour: 0]))
        let out = a.baselines.standouts
        XCTAssertLessThanOrEqual(out.count, 5)
        XCTAssertEqual(out.map(\.score), out.map(\.score).sorted(by: >))
        XCTAssertTrue(out.allSatisfy { $0.score >= A.Reading.minimumScore }, "only lines that pass")
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        XCTAssertNil(byID["them:A.talkShare"], "in a 1:1 the owner's share says it")
        XCTAssertNotNil(byID["me:A.talkShare"])
        XCTAssertNil(byID["me:A.cutOffsPerHour"], "and who cut in says who was cut off")
        XCTAssertEqual(byID["them:A.cutInsPerHour"]?.text, "cut in on you 2 times (4 an hour); usually 0 an hour in 1:1s with you")
        XCTAssertEqual(byID["them:A.cutInsPerHour"]?.evidence, .moment(15), "the first time")
        XCTAssertEqual(byID["them:A.questionsPerHour"]?.text, "asked 3 questions (6 an hour); usually 0 an hour in 1:1s with you")
        XCTAssertEqual(byID["them:A.questionsPerHour"]?.evidence, .moment(15), "the first question")
        XCTAssertEqual(a.baselines.person("me:A")?[.cutOffsPerHour]?.standing, .above)
    }

    func testTheSentenceSaysTheCountOfThisCallNotARoundedRate() {
        // One cut-in and one question in two and a half hours are 0.4 an hour.
        XCTAssertEqual(MeetingFindings.did(.cutInsPerHour, 0.4, count: 1, you: true), "cut in 1 time (0 an hour)")
        XCTAssertEqual(MeetingFindings.did(.questionsPerHour, 0.4, count: 1, you: false), "asked 1 question (0 an hour)")
        XCTAssertEqual(MeetingFindings.did(.cutInsPerHour, 0, count: 0, you: true), "did not cut in")
        XCTAssertEqual(MeetingFindings.did(.cutInsPerHour, 0, count: 0, you: false), "did not cut in on you")
        XCTAssertEqual(MeetingFindings.did(.cutOffsPerHour, 5, count: 3, you: true), "were cut off 3 times (5 an hour)")
        XCTAssertEqual(MeetingFindings.did(.cutOffsPerHour, 2, count: 1, you: false), "was cut off by you 1 time (2 an hour)")
        XCTAssertEqual(MeetingFindings.did(.questionsPerHour, 0, count: 0, you: false), "asked no questions")
    }

    func testAGroupHasAtMostTwoLinesAboutOnePerson() {
        let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        let r = call(minutes: 60, names: trio, title: "Team", [
            ("me:A", 0, 10, "Start."),
            ("them:A", 12, 300, "A very long turn with a question? " + Array(repeating: "word", count: 1400).joined(separator: " ")),
            ("them:B", 301, 311, "Fine."),
            ("them:A", 312, 330, "Why? " + Array(repeating: "word", count: 80).joined(separator: " ")),
            ("them:B", 331, 341, "Because."),
            ("them:A", 342, 360, "How? " + Array(repeating: "word", count: 80).joined(separator: " ")),
        ])
        let usual: [PersonMetric: Double] = [.questionsPerHour: 0, .longestTurn: 20, .averageTurn: 10, .wordsPerMinute: 150, .fillersPerMinute: 1]
        let history = (1...6).map { i in
            past("t\(i)", daysAgo: Double(i * 7), title: "Team", shares: [(owner, 0.4), (sam, 0.3), ("Jo Park", 0.3)], person: usual, onlyFor: sam)
        }
        let a = analytics(r, history)
        XCTAssertEqual(a.baselines.standouts.filter { $0.subject == "them:A" }.count, 2, "Sam has more that is unusual, but two lines")
        XCTAssertGreaterThan(a.baselines.person("them:A")!.readings.values.filter(\.stoodOut).count, 2)
    }

    func testAStandoutPointsAtItsEvidence() {
        let r = call(minutes: 60, title: "Dana / Sam", [
            ("me:A", 0, 40, "A long start from me."),
            ("me:A", 100, 400, "Then a very long turn."),
            ("them:A", 420, 430, "Why?"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: analytics(r, oneOnOnes(person: [.longestTurn: 60], onlyFor: owner)).baselines.standouts.map { ($0.id, $0) })
        XCTAssertEqual(byID["me:A.longestTurn"]?.evidence, .moment(100))
        XCTAssertEqual(byID["me:A.longestTurn"]?.text, "held one turn for 5 min; usually up to 1 min in your 1:1s with Sam")
    }

    /// One long turn made the average turn stand out too, so "What stood out" said one thing twice, at the same
    /// moment. The typical turn is the median, which one long turn does not move, and a person's turn numbers
    /// give at most one line.
    func testOneLongTurnIsOneLineAndDoesNotMoveTheTypicalTurn() {
        var turns: [Line] = []
        var t = 0.0
        for i in 0..<12 {
            turns.append(("me:A", t, t + 8, "Point \(i)."))
            turns.append(("them:A", t + 9, t + 17, "Reply \(i)."))
            t += 18
        }
        turns.append(("me:A", t, t + 300, "Then a very long turn."))
        turns.append(("them:A", t + 301, t + 309, "Why?"))
        let r = call(minutes: 60, title: "Dana / Sam", turns)
        let a = analytics(r, oneOnOnes(person: [.longestTurn: 30, .averageTurn: 8], onlyFor: owner))
        let me = a.speakers.first(where: \.isOwner)!
        XCTAssertEqual(me.averageTurn, 8, accuracy: 0.5, "the typical turn is the median")
        let mine = a.baselines.standouts.filter { $0.subject == "me:A" }.map(\.id)
        XCTAssertTrue(mine.contains("me:A.longestTurn"), "\(mine)")
        XCTAssertFalse(mine.contains("me:A.averageTurn"), "\(mine)")
    }

    /// Two lines from one cause: the owner's talk share and the owner's share with one person keep the stronger.
    func testOneLinePerCauseKeepsTheStrongerOfRelatedLines() {
        typealias S = MeetingAnalytics.Standout
        let list = [
            S(id: "me:A.averageTurn", subject: "me:A", text: "a", evidence: nil, score: 3),
            S(id: "me:A.longestTurn", subject: "me:A", text: "b", evidence: nil, score: 5),
            S(id: "me:A.talkShare", subject: "me:A", text: "c", evidence: nil, score: 4),
            S(id: "with.them:B", subject: "me:A", text: "d", evidence: nil, score: 6),
            S(id: "them:A.averageTurn", subject: "them:A", text: "e", evidence: nil, score: 3),
        ]
        XCTAssertEqual(MeetingAnalytics.Baselines.onePerCause(list).map(\.id), ["me:A.longestTurn", "with.them:B", "them:A.averageTurn"])
    }

    /// The words of turn lines: a longest turn above the usual reads as a ceiling, one below it as a range, and the
    /// typical turn does not say "usually" two times.
    func testTurnLinesSayWhatIsUnusual() {
        let history: [Double] = [20, 40, 60, 80, 90]
        let ctx = MeetingAnalytics.Context(kind: .series, meetings: 5, label: "in Weekly sync")
        let above = MeetingAnalytics.Reading(value: 300, history: history, margin: 20)
        XCTAssertTrue(MeetingFindings.sentence(.longestTurn, above, you: true, context: ctx).contains("usually up to"))
        let below = MeetingAnalytics.Reading(value: 5, history: history, margin: 20)
        let low = MeetingFindings.sentence(.longestTurn, below, you: true, context: ctx)
        XCTAssertFalse(low.contains("up to"), low)
        XCTAssertTrue(low.contains("usually 20 s to 1 min 30 s") || low.contains("usually 20 to"), low)
        let typical = MeetingFindings.sentence(.averageTurn, above, you: true, context: ctx)
        XCTAssertEqual(typical.components(separatedBy: "usually").count - 1, 1, typical)
    }

    /// A median turn of a few seconds can stand out, also below the usual.
    func testATypicalTurnMarginFitsShortTurns() {
        let u = MeetingAnalytics.Usual([4, 5, 5, 6, 6, 7])!
        XCTAssertLessThanOrEqual(PersonMetric.averageTurn.margin(u), 3)
    }

    /// The topic label names every topic that put a meeting in the context, or says how many more there are.
    func testATopicLabelNamesAllSharedTopics() {
        typealias B = MeetingAnalytics.Baselines
        XCTAssertEqual(B.topics(["Budget"]), "about Budget")
        XCTAssertEqual(B.topics(["Budget", "Roadmap"]), "about Budget or Roadmap")
        XCTAssertEqual(B.topics(["Budget", "Roadmap", "Hiring"]), "about Budget, Roadmap, or Hiring")
        XCTAssertEqual(B.topics(["Budget", "Roadmap", "Hiring", "Pricing", "Legal"]), "about Budget, Roadmap, Hiring, or 2 more of its topics")
    }

    func testAnOrdinaryCallHasNothingToSay() {
        let b = analytics(oneOnOne(dana: 62), oneOnOnes()).baselines
        XCTAssertEqual(b.standouts, [])
        XCTAssertEqual(b.person("me:A")?[.talkShare]?.standing, .usual)
        XCTAssertTrue(b.hasHistory)
        XCTAssertTrue(b.hasFirmHistory)
    }

    // MARK: Facts

    func testFactsCountPerHourWithAQuarterHourAtLeast() {
        var r = call(minutes: 5, names: ["me:A": "Dana Lee"], [
            ("me:A", 0, 30, "One? Two? " + Array(repeating: "word", count: 58).joined(separator: " ")),
            ("me:A", 31, 40, "Three?"),
            ("them:A", 41, 60, "An unnamed voice."),
        ])
        r.kind = "Standup"
        r.tags = ["Budget"]
        r.decisions = [Decision(text: "One")]
        let f = MeetingFacts(record: r, owner: owner)
        XCTAssertEqual(f.people.map(\.name), ["Dana Lee"], "a voice with no name cannot be followed")
        XCTAssertEqual(f.voices, 2)
        XCTAssertEqual(f.size, .oneOnOne)
        XCTAssertNil(f.partner, "the other voice has no name")
        XCTAssertEqual(f.owner?.values[.questionsPerHour], 8, "two lines with a question in a quarter of an hour")
        XCTAssertEqual(f.owner?.values[.talkShare], 39.0 / 58)
        XCTAssertEqual(f.owner?.values[.longestTurn], 40)
        XCTAssertEqual(f.owner?.values[.cutInsPerHour], 0, "the microphone and the call both have speech, so none is a count")
        XCTAssertEqual(f.series, "weekly sync")
        XCTAssertEqual(f.values[.length], 300)
        XCTAssertEqual(f.values[.decisions], 1)
        XCTAssertEqual(f.values[.voices], 2)
        XCTAssertNil(f.values[.value], "the rating comes from the coach's review")
        XCTAssertEqual(f.kind, "Standup")
        XCTAssertEqual(MeetingFacts.Size(voices: 3), .small)
        XCTAssertEqual(MeetingFacts.Size(voices: 8), .medium)
        XCTAssertEqual(MeetingFacts.Size(voices: 9), .large)
    }

    func testAMissingValueIsAbsentFromTheFacts() {
        var r = call([("me:A", 0, 30, "In the room."), ("me:B", 31, 60, "On the same microphone.")])
        r.summary = nil
        var f = MeetingFacts(record: r, owner: owner)
        XCTAssertNil(f.values[.screens], "no screen capture is not 0 screens")
        XCTAssertNil(f.values[.decisions], "no summary is not 0 decisions")
        XCTAssertNil(f.values[.actionItems])
        XCTAssertNil(f.owner?.values[.cutInsPerHour], "one track cannot show who talked over whom")
        XCTAssertNil(f.owner?.values[.cutOffsPerHour])
        r.summary = "Nothing was decided."
        r.screens = []
        f = MeetingFacts(record: r, owner: owner)
        XCTAssertEqual(f.values[.screens], 0, "capture was on, and nobody shared")
        XCTAssertEqual(f.values[.decisions], 0)
    }

    func testAVoiceThatSaidAlmostNothingDoesNotChangeTheSetting() {
        let names = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        let r = call(names: names, [("me:A", 0, 300, "A."), ("them:A", 300, 600, "B."), ("them:B", 601, 604, "Hi."), ("them:C", 605, 608, "Hm.")])
        let f = MeetingFacts(record: r, owner: owner)
        XCTAssertEqual(f.voices, 4)
        XCTAssertEqual(f.mainVoices, 2, "three seconds are not a third and a fourth person")
        XCTAssertEqual(f.size, .oneOnOne)
        XCTAssertEqual(f.partner?.name, "Sam Carter")
        XCTAssertEqual(f.values[.voices], 4, "the count of voices stays what it is")
    }

    func testOnlyACalendarOrCustomTitleMakesASeries() {
        var r = call(title: nil, [("me:A", 0, 30, "Hi.")])
        XCTAssertNil(MeetingFacts(record: r, owner: owner).series, "named after its app")
        r.generatedTitle = "Team sync"
        XCTAssertNil(MeetingFacts(record: r, owner: owner).series, "the model can give two unrelated calls one title")
        r.customTitle = "Team  Sync"
        XCTAssertEqual(MeetingFacts(record: r, owner: owner).series, "team sync")
    }

    func testAJoinedMeetingsLengthIsItsAudio() {
        var r = call(minutes: 120, [("me:A", 0, 30, "First part."), ("me:A", 1800, 1830, "Second part.")])
        r.parts = [CallPart(start: start, end: start.addingTimeInterval(1800), offset: 0),
                   CallPart(start: start.addingTimeInterval(5400), end: start.addingTimeInterval(7200), offset: 1800)]
        XCTAssertEqual(MeetingFacts(record: r, owner: owner).values[.length], 3600, "without the hour between the two recordings")
    }

    func testTheFactsCacheReadsOnlyTheMeetingsThatChanged() {
        let cache = MeetingFactsCache()
        var a = call(id: "a", [("me:A", 0, 10, "Hi.")]), b = call(id: "b", [("me:A", 0, 10, "Hi.")])
        var failed = call(id: "f", [("me:A", 0, 10, "Hi.")])
        failed.status = .failed
        let empty = call(id: "e", [])
        XCTAssertEqual(cache.facts(for: [a, b, failed, empty], owner: owner).map(\.id), ["a", "b"], "only written meetings with speech")
        XCTAssertEqual(cache.readCount, 2)
        XCTAssertEqual(cache.facts(for: [a, b], owner: owner).count, 2)
        XCTAssertEqual(cache.readCount, 2, "nothing changed, nothing read")
        a.summary = "A new summary changes no number."
        b.speakerNames["me:A"] = "Sam Carter"
        let again = cache.facts(for: [a, b], owner: owner)
        XCTAssertEqual(cache.readCount, 3, "one meeting changed, one meeting read")
        XCTAssertEqual(again[1].people.map(\.name), ["Sam Carter"])
        XCTAssertEqual(cache.facts(for: [a], owner: owner).count, 1)
        XCTAssertEqual(cache.facts(for: [a, b], owner: owner).count, 2)
        XCTAssertEqual(cache.readCount, 4, "a meeting that left the list was forgotten")
        _ = cache.facts(for: [a, b], owner: "Sam Carter")
        XCTAssertEqual(cache.readCount, 6, "another owner changes who you are in every meeting")
    }

    // MARK: Wording

    func testTheWordsForANumberAndItsRange() {
        func usual(_ values: [Double]) -> A.Usual { A.Usual(values)! }
        let context = A.Context(kind: .oneOnOne, meetings: 8, label: "in 1:1s with you")
        XCTAssertEqual(MeetingFindings.range(.talkShare, usual([0.3, 0.3, 0.4, 0.4, 0.35])), "30 to 40%")
        XCTAssertEqual(MeetingFindings.range(.talkShare, usual([0.35, 0.35, 0.35])), "35%")
        XCTAssertEqual(MeetingFindings.range(PersonMetric.wordsPerMinute, usual([150, 150, 165, 165])), "150 to 165")
        XCTAssertEqual(MeetingFindings.range(.fillersPerMinute, usual([1, 1, 2.1, 2.1])), "1.0 to 2.1")
        XCTAssertEqual(MeetingFindings.range(.longestTurn, usual([15, 15, 25, 25])), "15 to 25 s")
        XCTAssertEqual(MeetingFindings.range(.longestTurn, usual([60, 60, 130, 130])), "1 min to 2 min 10 s")
        XCTAssertEqual(MeetingFindings.range(.responseGap, usual([0.4, 0.4, 0.9, 0.9])), "0.4 to 0.9 s")
        XCTAssertEqual(MeetingFindings.range(.length, usual([1500, 1500, 2100, 2100])), "25 to 35 min")
        XCTAssertEqual(MeetingFindings.range(.length, usual([3000, 3000, 4200, 4200])), "50 min to 1 h 10 min")
        XCTAssertEqual(MeetingFindings.range(.value, usual([2, 2, 3, 3])), "medium to high")
        XCTAssertEqual(MeetingFindings.range(.silenceShare, usual([0.03, 0.03, 0.08, 0.08])), "3 to 8%")
        XCTAssertEqual(MeetingFindings.did(.talkShare, 0.6, you: false), "talked 60% of the time")
        XCTAssertEqual(MeetingFindings.did(.responseGap, 2.44, you: false), "took 2.4 s to answer")
        XCTAssertEqual(MeetingFindings.value(.talkShare, 0.6), "60%")
        XCTAssertEqual(MeetingFindings.value(.averageTurn, 48), "48 s")
        let reading = A.Reading(value: 0.6, history: [0.3, 0.3, 0.4, 0.4, 0.35], metric: PersonMetric.talkShare)
        XCTAssertEqual(MeetingFindings.sentence(.talkShare, reading, you: false, context: context),
                       "talked 60% of the time; usually 30 to 40% in 1:1s with you")
        XCTAssertEqual(MeetingFindings.usually(.questionsPerHour, usual([3, 3, 6, 6, 4]), context: context), "usually 3 to 6 an hour in 1:1s with you")
        XCTAssertEqual(MeetingFindings.basis(usual([3, 3, 6])), "from 3 meetings")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .oneOnOne, meetings: 8, label: "in your 1:1s with Sam")), "Compared with your 8 earlier 1:1s with Sam")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .ownOneOnOnes, meetings: 5, label: "in your 1:1s")), "Compared with your 5 earlier 1:1s")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .setting, meetings: 8, label: "in meetings of 3 to 4 people")),
                       "Compared with 8 earlier meetings of 3 to 4 people")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .setting, meetings: 4, label: "in monthly update meetings of 3 to 4 people")),
                       "Compared with 4 earlier monthly update meetings of 3 to 4 people")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .series, meetings: 1, label: "in Weekly sync")), "Compared with 1 earlier meeting in Weekly sync")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .recent, meetings: 20, label: "in your last 20 meetings")), "Compared with your last 20 meetings")
    }
}
