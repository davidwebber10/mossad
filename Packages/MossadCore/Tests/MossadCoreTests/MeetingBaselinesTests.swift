import XCTest
@testable import MossadCore

/// One call against what is normal in the owner's earlier meetings.
final class MeetingBaselinesTests: XCTestCase {
    private typealias A = MeetingAnalytics
    private typealias Line = (key: String, start: Double, end: Double, text: String)

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let owner = "Dana Lee"

    // MARK: Helpers

    private func call(id: String = "now", minutes: Double = 30, names: [String: String] = ["me:A": "Dana Lee", "them:A": "Sam Carter"],
                      title: String? = "Weekly sync", _ lines: [Line]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.speakerNames = names
        r.calendarTitle = title
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

    private func analytics(_ r: CallRecord, _ history: [MeetingFacts], value: (String) -> MeetingValue.Rating? = { _ in nil }) -> A {
        A(record: r, owner: owner, history: history, value: value)
    }

    // MARK: The usual range

    func testTheUsualRangeIsTheMiddleOfTheHistory() {
        XCTAssertNil(A.Usual([0.3, 0.4]), "two meetings say nothing about what is normal")
        let u = A.Usual([0.50, 0.30, 0.35, 0.40, 0.10, 0.36])!
        XCTAssertEqual(u.samples, 6)
        XCTAssertEqual(u.low, 0.30, accuracy: 0.0001)
        XCTAssertEqual(u.high, 0.40, accuracy: 0.0001)
        XCTAssertEqual(u.median, 0.355, accuracy: 0.0001)
        let three = A.Usual([10, 20, 30])!
        XCTAssertEqual(three.low, 14, accuracy: 0.0001)
        XCTAssertEqual(three.high, 26, accuracy: 0.0001)
    }

    func testANumberStandsOutOnlyWellOutsideTheRange() {
        let history = [0.30, 0.32, 0.35, 0.38, 0.40]
        func reading(_ v: Double) -> A.Reading { A.Reading(value: v, history: history, margin: PersonMetric.talkShare.margin) }
        XCTAssertEqual(reading(0.36).standing, .usual)
        XCTAssertEqual(reading(0.42).standing, .usual, "a little over the range is not news")
        XCTAssertEqual(reading(0.42).score, 0)
        XCTAssertEqual(reading(0.60).standing, .above)
        XCTAssertEqual(reading(0.10).standing, .below)
        XCTAssertGreaterThan(reading(0.60).score, reading(0.50).score)
        let none = A.Reading(value: 0.6, history: [0.3], margin: PersonMetric.talkShare.margin)
        XCTAssertNil(none.usual)
        XCTAssertNil(none.standing)
        XCTAssertFalse(none.stoodOut)
    }

    // MARK: Contexts

    func testTheSeriesComesFirst() {
        let history = [
            past("s1", daysAgo: 7, shares: [(owner, 0.5), ("Sam Carter", 0.5)]),
            past("s2", daysAgo: 14, shares: [(owner, 0.5), ("Sam Carter", 0.5)]),
            past("s3", daysAgo: 21, shares: [(owner, 0.6), ("Sam Carter", 0.4)]),
            past("x1", daysAgo: 2, title: "Planning", shares: [(owner, 0.9), ("Sam Carter", 0.1)]),
        ]
        let b = analytics(oneOnOne(dana: 50, title: "Weekly sync"), history).baselines
        XCTAssertEqual(b.earlier, 4)
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .series, meetings: 3, label: "in Weekly sync"))
        XCTAssertEqual(b.person("me:A")?.context?.kind, .series)
        XCTAssertEqual(b.meeting.context, .init(kind: .series, meetings: 3, label: "in Weekly sync"))
        XCTAssertEqual(b.person("them:A")?[.talkShare]?.usual?.samples, 3)
    }

    func testAOneOnOneIsComparedWithTheOtherOneOnOnesWithThatPerson() {
        // Two of the series are not enough, so the 1:1s with Sam under any title count.
        let history = [
            past("s1", daysAgo: 7, title: "Dana / Sam", shares: [(owner, 0.65), ("Sam Carter", 0.35)]),
            past("s2", daysAgo: 14, title: "Dana / Sam", shares: [(owner, 0.70), ("Sam Carter", 0.30)]),
            past("o1", daysAgo: 21, title: "Catch up", shares: [(owner, 0.60), ("Sam Carter", 0.40)]),
            past("o2", daysAgo: 28, title: "Budget", shares: [(owner, 0.65), ("Sam Carter", 0.35)]),
            past("g1", daysAgo: 3, title: "Team", shares: [(owner, 0.2), ("Sam Carter", 0.2), ("Jo Park", 0.6)]),
            past("j1", daysAgo: 4, title: "Dana / Jo", shares: [(owner, 0.5), ("Jo Park", 0.5)]),
            past("u1", daysAgo: 5, title: "Unnamed", voices: 3, shares: [(owner, 0.5), ("Sam Carter", 0.5)]),
        ]
        let a = analytics(oneOnOne(dana: 40), history)
        let sam = a.baselines.person("them:A")!, dana = a.baselines.person("me:A")!
        XCTAssertEqual(sam.context, .init(kind: .oneOnOne, meetings: 4, label: "in 1:1s with you"))
        XCTAssertEqual(dana.context, .init(kind: .oneOnOne, meetings: 4, label: "in your 1:1s with Sam"))
        XCTAssertEqual(sam[.talkShare]?.value, 0.6)
        XCTAssertEqual(sam[.talkShare]?.standing, .above)
        XCTAssertEqual(MeetingFindings.usually(.talkShare, sam[.talkShare]!.usual!, context: sam.context!), "usually 33 to 37% in 1:1s with you")
        XCTAssertEqual(sam.shareTrend, [0.35, 0.40, 0.30, 0.35, 0.6], "oldest first, this call last")
        XCTAssertEqual(a.baselines.meeting.context?.label, "in your 1:1s with Sam")
        XCTAssertEqual(a.baselines.ownerWith, [], "in a 1:1 the owner's own row says it")
    }

    func testAGroupIsComparedWithMeetingsOfItsSizeAndKind() {
        let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        var r = call(names: trio, title: "Roadmap", [("me:A", 0, 30, "A."), ("them:A", 30, 60, "B."), ("them:B", 60, 100, "C.")])
        r.kind = "Monthly update"
        r.tags = ["Budget"]
        func group(_ id: String, _ days: Double, kind: String? = nil, tags: [String] = [], voices: Int = 3) -> MeetingFacts {
            past(id, daysAgo: days, title: "Other \(id)", voices: voices, kind: kind, tags: tags, shares: [(owner, 0.3), ("Sam Carter", 0.3)])
        }
        let sameKind = [group("k1", 1, kind: "monthly update"), group("k2", 2, kind: "Monthly update"), group("k3", 3, kind: "Monthly update")]
        let sameTopic = [group("t1", 4, tags: ["budget"]), group("t2", 5, tags: ["Budget", "Hiring"]), group("t3", 6, tags: ["Budget"])]
        let sameSize = [group("z1", 7), group("z2", 8, voices: 4), group("z3", 9)]
        let large = [group("l1", 10, voices: 9), group("l2", 11, voices: 9), group("l3", 12, voices: 9)]

        var b = analytics(r, sameKind + sameTopic + sameSize + large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .setting, meetings: 3, label: "in monthly update meetings of 3 to 4 people"))
        b = analytics(r, sameTopic + sameSize + large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .setting, meetings: 3, label: "in meetings of 3 to 4 people on these topics"))
        b = analytics(r, sameSize + large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .setting, meetings: 3, label: "in meetings of 3 to 4 people"))
        XCTAssertEqual(b.meeting.context?.label, "in meetings of 3 to 4 people")
        b = analytics(r, large).baselines
        XCTAssertEqual(b.person("them:A")?.context, .init(kind: .person, meetings: 3, label: "in all 3 meetings with you"))
        XCTAssertEqual(b.person("me:A")?.context, .init(kind: .person, meetings: 3, label: "in all 3 of your meetings"))
        XCTAssertEqual(b.meeting.context, .init(kind: .recent, meetings: 3, label: "in your last 3 meetings"))
        XCTAssertNil(b.person("them:B")?.context, "Jo was in none of them: not enough history yet")
        XCTAssertEqual(b.person("them:B")?.readings, [:])
        XCTAssertTrue(b.hasHistory)
    }

    func testOnlyEarlierMeetingsAreHistory() {
        let r = oneOnOne(dana: 50)
        let later = (1...4).map { past("l\($0)", daysAgo: -Double($0), title: "Dana / Sam", shares: [(owner, 0.5), ("Sam Carter", 0.5)]) }
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

    func testTheOwnersShareIsComparedForEachOtherPersonOfAGroup() {
        let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        let r = call(names: trio, title: nil, [("me:A", 0, 70, "A."), ("them:A", 70, 85, "B."), ("them:B", 85, 100, "C.")])
        let withSam = (1...4).map { past("s\($0)", daysAgo: Double($0), title: "Other \($0)", voices: 3, shares: [(owner, 0.40 + Double($0) / 100), ("Sam Carter", 0.3)]) }
        let withJo = (1...2).map { past("j\($0)", daysAgo: Double($0), title: "Jo \($0)", voices: 6, shares: [(owner, 0.2), ("Jo Park", 0.3)]) }
        let a = analytics(r, withSam + withJo)
        XCTAssertEqual(a.baselines.ownerWith.map(\.id), ["them:A"], "two meetings with Jo are not enough")
        let w = a.baselines.ownerWith[0]
        XCTAssertEqual(w.context, .init(kind: .setting, meetings: 4, label: "in meetings of 3 to 4 people with Sam"))
        XCTAssertEqual(w.reading.value, 0.7)
        XCTAssertEqual(w.reading.standing, .above)
        let said = a.baselines.standouts.first { $0.id == "with.them:A" }
        XCTAssertEqual(said?.subject, "me:A")
        XCTAssertEqual(said?.text, "talked 70% of the time with Sam Carter; usually 42 to 43% in meetings of 3 to 4 people with Sam")
        XCTAssertEqual(said?.evidence, .person("them:A"))
    }

    // MARK: The meeting

    func testTheMeetingIsComparedWithItsSeriesAndTheCoachsRatings() {
        var r = call(minutes: 60, [("me:A", 0, 50, "A."), ("them:A", 50, 100, "B.")])
        r.decisions = [Decision(text: "One", at: 40), Decision(text: "Two", at: 20), Decision(text: "Three"), Decision(text: "Four")]
        let history = (1...5).map {
            past("s\($0)", daysAgo: Double($0 * 7), shares: [(owner, 0.5), ("Sam Carter", 0.5)],
                 meeting: [.length: 1500 + Double($0) * 60, .decisions: 0, .voices: 2, .actionItems: 3])
        }
        let ratings: [String: MeetingValue.Rating] = ["s1": .high, "s2": .high, "s3": .medium, "s4": .high]
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
        XCTAssertEqual(m[.value]?.usual?.samples, 4, "only the rated meetings")
        XCTAssertEqual(m[.value]?.standing, .below)
        XCTAssertEqual(a.facts.values[.value], 1)
        let texts = Dictionary(uniqueKeysWithValues: a.baselines.standouts.map { ($0.id, $0) })
        XCTAssertEqual(texts["meeting.length"]?.text, "The meeting ran 1 h; usually 27 to 29 min in Weekly sync")
        XCTAssertNil(texts["meeting.length"]?.evidence)
        XCTAssertEqual(texts["meeting.decisions"]?.text, "4 decisions; usually 0 in Weekly sync")
        XCTAssertEqual(texts["meeting.decisions"]?.evidence, .moment(20), "the first decision")
        XCTAssertEqual(texts["meeting.value"]?.text, "The coach rated it low; usually high in Weekly sync")
        XCTAssertEqual(texts["meeting.actionItems"]?.text, "No action items; usually 3 in Weekly sync")
    }

    func testTheScheduleSaysALateStartAndAnOverrun() {
        var r = oneOnOne(dana: 50)
        XCTAssertNil(analytics(r, []).baselines.schedule, "no invite")
        r.plannedStart = start.addingTimeInterval(-6 * 60)
        r.plannedEnd = start.addingTimeInterval(18 * 60)
        let b = analytics(r, []).baselines
        XCTAssertEqual(b.schedule?.startDelay, 360)
        XCTAssertEqual(b.schedule?.overrun, 720)
        XCTAssertEqual(b.schedule?.plannedLength, 1440)
        XCTAssertEqual(b.standouts.map(\.text), ["Ran 12 min over the planned end", "Started 6 min late"])
        XCTAssertEqual(b.standouts.map(\.evidence), [.moment(1080), nil], "play from the planned end")

        r.plannedStart = start.addingTimeInterval(-60)
        r.plannedEnd = r.end.addingTimeInterval(-120)
        let quiet = analytics(r, []).baselines
        XCTAssertEqual(quiet.schedule?.startedLate, false)
        XCTAssertEqual(quiet.schedule?.ranOver, false)
        XCTAssertEqual(quiet.standouts, [])
    }

    // MARK: Trends

    func testTheTrendsFollowTheSeriesWithThisCallLast() {
        let r = oneOnOne(dana: 40, title: "Weekly sync")
        let both: [(String, Double)] = [(owner, 0.5), ("Sam Carter", 0.5)], onlySam: [(String, Double)] = [("Sam Carter", 1)]
        let history = (1...14).map { i -> MeetingFacts in
            past("s\(i)", daysAgo: Double(i * 7), shares: i == 2 ? onlySam : both, meeting: [.length: 1800 + Double(i)])
        }
        let ratings: [String: MeetingValue.Rating] = ["s1": .high, "s3": .low]
        let review = CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil,
                                 value: MeetingValue(rating: .medium, reason: "", action: .keep, suggestion: ""))
        let t = A(record: r, owner: owner, review: review, history: history, value: { ratings[$0] }).baselines.trends!
        XCTAssertEqual(t.context, .init(kind: .series, meetings: 11, label: "in Weekly sync"))
        XCTAssertEqual(t.length.count, 12)
        XCTAssertEqual(t.length.map(\.id).prefix(2), ["s11", "s10"], "oldest first")
        XCTAssertEqual(t.length.last?.id, "now")
        XCTAssertEqual(t.talkShare.map(\.value).suffix(3), [0, 0.5, 0.4], "a meeting where the owner said nothing is 0%")
        XCTAssertEqual(t.value.map(\.value), [1, 3, 2], "only the rated meetings")
        XCTAssertEqual(t.value.map(\.id), ["s3", "s1", "now"])
    }

    func testATrendNeedsThreePoints() {
        let r = oneOnOne(dana: 40)
        let one = [past("s1", daysAgo: 7, title: "Dana / Sam", shares: [(owner, 0.5), ("Sam Carter", 0.5)], meeting: [.length: 1800])]
        XCTAssertNil(analytics(r, one).baselines.trends)
        // Not the series, but 1:1s with Sam.
        let two = one + [past("o1", daysAgo: 9, title: "Catch up", shares: [(owner, 0.5), ("Sam Carter", 0.5)], meeting: [.length: 1800])]
        let t = analytics(r, two).baselines.trends
        XCTAssertEqual(t?.context, .init(kind: .oneOnOne, meetings: 2, label: "in your 1:1s with Sam"))
        XCTAssertEqual(t?.length.count, 3)
        XCTAssertEqual(t?.value, [], "no ratings, no line")
    }

    // MARK: What stood out

    func testWhatStoodOutRanksTheNumbersFurthestFromUsual() {
        // Dana talks 20 s of 100 s, in one turn; Sam cuts in twice and asks many questions.
        let r = call(minutes: 60, title: "Dana / Sam", [
            ("me:A", 0, 20, "So the plan is this."),
            ("them:A", 15, 40, "Wait, why that date? Who agreed?"),
            ("them:A", 41, 60, "And who pays for it?"),
            ("me:A", 70, 75, "We do."),
            ("them:A", 73, 100, "No, that is not right at all, is it?"),
        ])
        let history = (1...6).map { i in
            past("s\(i)", daysAgo: Double(i * 7), title: "Dana / Sam", shares: [(owner, 0.6), ("Sam Carter", 0.4)],
                 person: [.questionsPerHour: 0, .cutInsPerHour: 0, .cutOffsPerHour: 0, .longestTurn: 20 + Double(i), .averageTurn: 12, .wordsPerMinute: 150])
        }
        let a = analytics(r, history)
        let out = a.baselines.standouts
        XCTAssertLessThanOrEqual(out.count, 5)
        XCTAssertEqual(out.map(\.score), out.map(\.score).sorted(by: >))
        XCTAssertLessThanOrEqual(out.filter { $0.subject == "them:A" }.count, 3, "at most three about one person of a 1:1")
        XCTAssertLessThanOrEqual(out.filter { $0.subject == "me:A" }.count, 3)
        let ids = Set(out.map(\.id))
        XCTAssertFalse(ids.contains("them:A.talkShare"), "in a 1:1 the owner's share says it")
        XCTAssertTrue(ids.contains("me:A.talkShare"))
        XCTAssertFalse(ids.contains("me:A.cutOffsPerHour"), "and who cut in says who was cut off")
        let cut = a.baselines.person("them:A")![.cutInsPerHour]!
        XCTAssertEqual(cut.value, 2)
        XCTAssertEqual(cut.standing, .above)
        let dana = a.baselines.person("me:A")!
        XCTAssertEqual(dana[.talkShare]?.standing, .below)
        XCTAssertEqual(dana[.cutOffsPerHour]?.standing, .above)
    }

    func testAGroupHasAtMostTwoLinesAboutOnePerson() {
        let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]
        let r = call(minutes: 60, names: trio, title: "Team", [
            ("me:A", 0, 10, "Start."),
            ("them:A", 8, 300, "A very long turn with a question? " + Array(repeating: "word", count: 1400).joined(separator: " ")),
            ("them:B", 301, 311, "Fine."),
            ("them:A", 312, 330, "Why? " + Array(repeating: "word", count: 80).joined(separator: " ")),
            ("them:B", 331, 341, "Because."),
            ("them:A", 342, 360, "How? " + Array(repeating: "word", count: 80).joined(separator: " ")),
        ])
        let usual: [PersonMetric: Double] = [.questionsPerHour: 0, .longestTurn: 20, .averageTurn: 10, .wordsPerMinute: 150, .fillersPerMinute: 1]
        let history = (1...5).map { i in
            past("t\(i)", daysAgo: Double(i * 7), title: "Team", shares: [(owner, 0.4), ("Sam Carter", 0.3), ("Jo Park", 0.3)], person: usual, onlyFor: "Sam Carter")
        }
        let out = analytics(r, history).baselines.standouts
        XCTAssertEqual(out.filter { $0.subject == "them:A" }.count, 2, "Sam has more that is unusual, but two lines")
        XCTAssertGreaterThan(analytics(r, history).baselines.person("them:A")!.readings.values.filter(\.stoodOut).count, 2)
    }

    func testAStandoutPointsAtItsEvidence() {
        let r = call(minutes: 60, title: "Dana / Sam", [
            ("me:A", 0, 40, "A long start from me."),
            ("them:A", 30, 55, "Cutting in with more than a word."),
            ("me:A", 60, 80, "Back to me again."),
            ("them:A", 75, 95, "And cutting in once more here."),
            ("me:A", 100, 400, "Then a very long turn."),
            ("them:A", 420, 430, "Why?"),
            ("me:A", 431, 433, "Because."),
            ("them:A", 434, 440, "How?"),
            ("me:A", 441, 443, "Like so."),
            ("them:A", 444, 450, "When?"),
        ])
        func history(_ numbers: [PersonMetric: Double], for name: String) -> [MeetingFacts] {
            (1...5).map { i in
                past("s\(i)", daysAgo: Double(i * 7), title: "Catch up \(i)", shares: [(owner, 0.85), ("Sam Carter", 0.15)], person: numbers, onlyFor: name)
            }
        }
        var byID = Dictionary(uniqueKeysWithValues: analytics(r, history([.longestTurn: 60], for: owner)).baselines.standouts.map { ($0.id, $0) })
        XCTAssertEqual(byID["me:A.longestTurn"]?.evidence, .moment(100))
        XCTAssertEqual(byID["me:A.longestTurn"]?.text, "held one turn for 5 min; usually 1 min in your 1:1s with Sam")
        XCTAssertEqual(byID.count, 1)

        byID = Dictionary(uniqueKeysWithValues: analytics(r, history([.questionsPerHour: 0, .cutInsPerHour: 0], for: "Sam Carter")).baselines.standouts.map { ($0.id, $0) })
        XCTAssertEqual(byID["them:A.cutInsPerHour"]?.evidence, .moment(30), "the first time Sam cut in")
        XCTAssertEqual(byID["them:A.cutInsPerHour"]?.text, "cut in 2 times an hour; usually 0 an hour in 1:1s with you")
        XCTAssertEqual(byID["them:A.questionsPerHour"]?.evidence, .moment(420), "the first question")
        XCTAssertEqual(byID["them:A.questionsPerHour"]?.subject, "them:A")
    }

    func testAUsualCallHasNothingToSay() {
        let history = (1...5).map { past("s\($0)", daysAgo: Double($0 * 7), title: "Dana / Sam", shares: [(owner, 0.5), ("Sam Carter", 0.5)]) }
        let b = analytics(oneOnOne(dana: 52), history).baselines
        XCTAssertEqual(b.standouts, [])
        XCTAssertEqual(b.person("me:A")?[.talkShare]?.standing, .usual)
        XCTAssertTrue(b.hasHistory)
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
        XCTAssertEqual(f.series, "weekly sync")
        XCTAssertEqual(f.values[.length], 300)
        XCTAssertEqual(f.values[.decisions], 1)
        XCTAssertEqual(f.values[.voices], 2)
        XCTAssertNil(f.values[.value], "the rating comes from the coach's review")
        XCTAssertEqual(f.kind, "Standup")
        XCTAssertEqual(MeetingFacts(record: call(title: nil, []), owner: owner).series, nil)
        XCTAssertEqual(MeetingFacts.Size(voices: 3), .small)
        XCTAssertEqual(MeetingFacts.Size(voices: 8), .medium)
        XCTAssertEqual(MeetingFacts.Size(voices: 9), .large)
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
        XCTAssertEqual(MeetingFindings.range(.talkShare, usual([0.3, 0.3, 0.4, 0.4])), "30 to 40%")
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
        XCTAssertEqual(MeetingFindings.did(.cutOffsPerHour, 5, you: true), "were cut off 5 times an hour")
        XCTAssertEqual(MeetingFindings.did(.cutOffsPerHour, 1, you: false), "was cut off 1 time an hour")
        XCTAssertEqual(MeetingFindings.did(.questionsPerHour, 0, you: false), "asked no questions")
        XCTAssertEqual(MeetingFindings.did(.responseGap, 2.44, you: false), "took 2.4 s to answer")
        XCTAssertEqual(MeetingFindings.value(.talkShare, 0.6), "60%")
        XCTAssertEqual(MeetingFindings.value(.averageTurn, 48), "48 s")
        let reading = A.Reading(value: 0.6, history: [0.3, 0.3, 0.4, 0.4], margin: PersonMetric.talkShare.margin)
        XCTAssertEqual(MeetingFindings.sentence(.talkShare, reading, you: false, context: context),
                       "talked 60% of the time; usually 30 to 40% in 1:1s with you")
        XCTAssertEqual(MeetingFindings.usually(.questionsPerHour, usual([3, 3, 6, 6]), context: context), "usually 3 to 6 an hour in 1:1s with you")
        XCTAssertEqual(MeetingFindings.compared(context), "Compared with 8 earlier meetings in 1:1s with you")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .series, meetings: 1, label: "in Weekly sync")), "Compared with 1 earlier meeting in Weekly sync")
        XCTAssertEqual(MeetingFindings.compared(A.Context(kind: .recent, meetings: 20, label: "in your last 20 meetings")), "Compared with your last 20 meetings")
    }
}
