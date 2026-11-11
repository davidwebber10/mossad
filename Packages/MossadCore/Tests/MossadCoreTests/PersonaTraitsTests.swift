import XCTest
@testable import MossadCore

/// The trait model: the confidence that code computes, the show rule, counter-evidence, settings, the owner's
/// answers, and the properties that must hold for any evidence.
final class PersonaTraitsTests: XCTestCase {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t0: Date { Self.t0 }

    /// One moment on a day after `t0`, in a call of its own.
    static func moment(_ day: Int, _ dimension: String = "order", _ value: String = "answer_first", call: String? = nil, strength: PersonaEvidence.Strength = .clear,
                       setting: PersonaSetting = .group, series: String? = nil, tags: [String] = [], at: TimeInterval = 60) -> PersonaEvidence {
        let id = call ?? "c\(day)"
        return PersonaEvidence(callID: id, date: t0.addingTimeInterval(Double(day) * 86_400), pointer: PersonaPointer(callID: id, at: at, line: "h\(day)"),
                               dimension: dimension, value: value, strength: strength, setting: setting, series: series ?? "series \(day)", tags: tags)
    }

    private func persona(_ evidence: [PersonaEvidence], texts: [String: PersonaText] = [:]) -> Persona {
        var p = Persona(person: "p1", updated: t0)
        p.evidence = evidence
        p.texts = texts
        return p
    }

    private func text(_ rating: PersonaText.Rating = .medium, calls: Int = 2) -> PersonaText {
        PersonaText(statement: "Sam asks for the answer before the reasons.", soDoThis: "Open with the answer in two sentences.", rating: rating,
                    written: t0, calls: calls, counter: 0)
    }

    private let id = "p1|order|answer_first|any"

    /// With the 2-call rule as if on, as the eval measures it; `testATwoCallTraitShowsOnlyAfterTheOwnersYesUntilRealAnswers` covers it off.
    private func trait(_ p: Persona, answers: [FindingAnswer] = [], twoCallRule: Bool? = true) -> PersonaTrait? {
        PersonaTraits.build(p, answers: answers, twoCallRule: twoCallRule).first { $0.id == id }
    }

    // MARK: The base

    func testTheBaseIsTheLowTenthOfWhatTheTrueRateCanBe() {
        let cases: [(Double, Double, Double)] = [(1, 0, 0.32), (2, 0, 0.46), (3, 0, 0.56), (4, 0, 0.63), (5, 0, 0.68), (8, 0, 0.77), (3, 1, 0.42), (5, 1, 0.55), (6, 1, 0.59)]
        for (s, c, expected) in cases {
            XCTAssertEqual(PersonaConfidence.base(support: s, counter: c), expected, accuracy: 0.01, "S \(s), C \(c)")
        }
    }

    // MARK: The show rule

    func testOneCallNeverShowsEvenWithAHighRating() throws {
        let t = try XCTUnwrap(trait(persona([Self.moment(1)], texts: [id: text(.high)])))
        XCTAssertLessThanOrEqual(t.confidence, 0.42, "the best one call can do")
        XCTAssertFalse(t.isShown)
        XCTAssertEqual(t.state, .hidden)
    }

    func testThreeCleanCallsShowAsLikely() throws {
        let t = try XCTUnwrap(trait(persona([Self.moment(1), Self.moment(5), Self.moment(9)], texts: [id: text()])))
        XCTAssertEqual(t.confidence, 0.56, accuracy: 0.01)
        XCTAssertTrue(t.isShown)
        XCTAssertEqual(t.label, "Likely")
        XCTAssertEqual(t.countLine, "seen in 3 of 3 calls")
    }

    func testTwoCallsShowOnlyWithAHighRatingTwoTopicsAndNoContradiction() throws {
        let two = [Self.moment(1, series: "budget"), Self.moment(4, series: "hiring")]
        XCTAssertTrue(try XCTUnwrap(trait(persona(two, texts: [id: text(.high)]))).isShown, "two topics, high")
        XCTAssertFalse(try XCTUnwrap(trait(persona(two, texts: [id: text(.medium)]))).isShown, "medium")
        let oneTopic = [Self.moment(1, series: "budget"), Self.moment(4, series: "budget")]
        let t = try XCTUnwrap(trait(persona(oneTopic, texts: [id: text(.high)])))
        XCTAssertEqual(t.confidence, 0.46, accuracy: 0.01)
        XCTAssertFalse(t.isShown, "one topic")
        let sameTag = [Self.moment(1, series: "a", tags: ["Budget"]), Self.moment(4, series: "b", tags: ["budget", "Hiring"])]
        XCTAssertFalse(try XCTUnwrap(trait(persona(sameTag, texts: [id: text(.high)]))).isShown, "one tag")
        let twoSettings = [Self.moment(1, setting: .oneOnOne, series: "budget"), Self.moment(4, setting: .group, series: "budget")]
        XCTAssertTrue(try XCTUnwrap(trait(persona(twoSettings, texts: [id: text(.high)]))).isShown, "two settings")
        let contra = two + [Self.moment(6, "order", "path_first", setting: .group)]
        XCTAssertFalse(try XCTUnwrap(trait(persona(contra, texts: [id: text(.high)]))).isShown, "a contradiction")
    }

    func testTwoCallsOnOneDayCountOnce() throws {
        let t = try XCTUnwrap(trait(persona([Self.moment(1, call: "a"), Self.moment(1, call: "b"), Self.moment(3)], texts: [id: text()])))
        XCTAssertEqual(t.supportDays, 2)
        XCTAssertFalse(t.isShown)
    }

    func testAWeakMomentCountsAsOneHalf() throws {
        let t = try XCTUnwrap(trait(persona([Self.moment(1), Self.moment(3), Self.moment(5, strength: .weak)], texts: [id: text()])))
        XCTAssertEqual(t.supportDays, 2.5)
        XCTAssertFalse(t.isShown)
    }

    func testFourCallsWithAHighRatingAreEstablished() throws {
        let t = try XCTUnwrap(trait(persona((1...4).map { Self.moment($0 * 3) }, texts: [id: text(.high)])))
        XCTAssertEqual(t.confidence, 0.73, accuracy: 0.01)
        XCTAssertEqual(t.label, "Established")
    }

    func testALowRatingLowersTheNumber() throws {
        let t = try XCTUnwrap(trait(persona((1...4).map { Self.moment($0 * 3) }, texts: [id: text(.low)])))
        XCTAssertEqual(t.confidence, 0.48, accuracy: 0.01)
        XCTAssertFalse(t.isShown)
    }

    func testNoSentenceMeansNotShownAndASentenceThatFailsTheWordCheckIsNotShown() throws {
        let three = [Self.moment(1), Self.moment(5), Self.moment(9)]
        XCTAssertEqual(try XCTUnwrap(trait(persona(three))).state, .candidate)
        var bad = text()
        bad.statement = "Sam is a skeptic."
        XCTAssertFalse(try XCTUnwrap(trait(persona(three, texts: [id: bad]))).isShown)
    }

    // MARK: Counter-evidence

    func testAnOldContradictionBeforeANewHabitOfAsManyDaysNoLongerCounts() throws {
        let soon = persona([Self.moment(1, "order", "path_first"), Self.moment(4), Self.moment(7), Self.moment(10)], texts: [id: text()])
        XCTAssertFalse(try XCTUnwrap(trait(soon)).isShown, "against, for, for, for within weeks: 3 for and 1 against stays hidden")
        let p = persona([Self.moment(1, "order", "path_first"), Self.moment(4), Self.moment(7), Self.moment(70)], texts: [id: text()])
        XCTAssertTrue(try XCTUnwrap(trait(p)).isShown, "the newest support 60 days or more after the contradiction")
        let twoOld = persona([Self.moment(1, "order", "path_first"), Self.moment(2, "order", "path_first"), Self.moment(3, "order", "path_first"),
                              Self.moment(4, "order", "path_first"), Self.moment(7), Self.moment(10), Self.moment(13)], texts: [id: text()])
        XCTAssertFalse(try XCTUnwrap(trait(twoOld)).isShown, "an older habit of more days still counts")
    }

    func testThreeForAndOneAgainstIsHiddenAndTheCounterEvidenceIsKept() throws {
        let p = persona([Self.moment(1), Self.moment(4), Self.moment(7), Self.moment(10, "order", "path_first")], texts: [id: text()])
        let t = try XCTUnwrap(trait(p))
        XCTAssertEqual(t.confidence, 0.42, accuracy: 0.01)
        XCTAssertFalse(t.isShown)
        XCTAssertEqual(t.counter.map(\.callID), ["c10"])
        XCTAssertEqual(t.countLine, "seen in 3 of 4 calls")
    }

    func testMoreSupportShowsWithTheCounterEvidenceListed() throws {
        let p = persona((1...6).map { Self.moment($0 * 2) } + [Self.moment(5, "order", "path_first")], texts: [id: text()])
        let t = try XCTUnwrap(trait(p))
        XCTAssertTrue(t.isShown)
        XCTAssertEqual(t.counter.count, 1)
    }

    func testAnotherValueThatIsNoOppositeIsNoCounterEvidence() throws {
        let p = persona([Self.moment(1), Self.moment(4), Self.moment(7), Self.moment(10, "order", "material_before")], texts: [id: text()])
        XCTAssertTrue(try XCTUnwrap(trait(p)).isShown)
    }

    func testANewerHabitWinsOverAnOlderOne() throws {
        let old = (1...3).map { Self.moment($0, "order", "path_first") }
        let new = (4...6).map { Self.moment($0 * 20) }
        let texts = [id: text(), "p1|order|path_first|any": text()]
        let traits = PersonaTraits.build(persona(old + new, texts: texts), answers: [])
        XCTAssertTrue(try XCTUnwrap(traits.first { $0.id == id }).isShown, "the newer value")
        XCTAssertFalse(try XCTUnwrap(traits.first { $0.id == "p1|order|path_first|any" }).isShown, "the older value")
    }

    func testOneToOneSupportAndGroupContradictionsGiveTwoTraitsWithACondition() {
        let oneOnOne = [1, 4, 7].map { Self.moment($0, "objection", "direct", setting: .oneOnOne) }
        let group = [2, 5, 8].map { Self.moment($0, "objection", "silent_then_later", setting: .group) }
        let direct = "p1|objection|direct|one_on_one", silent = "p1|objection|silent_then_later|group"
        let texts = [direct: text(), silent: text()]
        let traits = PersonaTraits.build(persona(oneOnOne + group, texts: texts), answers: [])
        XCTAssertEqual(Set(traits.filter(\.isShown).map(\.id)), [direct, silent])
        XCTAssertEqual(traits.first { $0.id == direct }?.condition, .oneOnOne)
        XCTAssertTrue(traits.first { $0.id == direct }?.counter.isEmpty == true)
    }

    func testAContradictionInsideOneOldTimeWeighsLessThanANewOne() throws {
        let support = (1...5).map { Self.moment($0 * 100) }
        let oldAgainst = persona(support + [Self.moment(1, "order", "path_first")], texts: [id: text()])
        let newAgainst = persona(support + [Self.moment(600, "order", "path_first")], texts: [id: text()])
        XCTAssertGreaterThan(try XCTUnwrap(trait(oldAgainst)).confidence, try XCTUnwrap(trait(newAgainst)).confidence)
    }

    // MARK: The owner's answers

    private func answer(_ verdict: FindingVerdict?, day: Int = 20, trait: String? = nil) -> FindingAnswer {
        let card = CoachFinding(id: "c9|trait|\(trait ?? id)", callID: "c9", date: t0, kind: .trait, text: "Sam asks for the answer.", skill: "", person: "p1",
                                trait: trait ?? id)
        return FindingAnswer(card, verdict: verdict, date: t0.addingTimeInterval(Double(day) * 86_400))
    }

    func testYesConfirmsForAnyCount() throws {
        let two = [Self.moment(1, series: "a"), Self.moment(4, series: "a")]
        let t = try XCTUnwrap(trait(persona(two, texts: [id: text()]), answers: [answer(.yes)]))
        XCTAssertEqual(t.state, .confirmed)
        XCTAssertTrue(t.isShown)
        XCTAssertEqual(t.label, "You confirmed")
    }

    func testNoLowersAndHidesUntilTwoNewCallsSupportIt() throws {
        let base = (1...4).map { Self.moment($0 * 3) }
        let no = answer(.no, day: 13)
        let t = try XCTUnwrap(trait(persona(base, texts: [id: text(.high)]), answers: [no]))
        XCTAssertEqual(t.confidence, 0.73 - 0.25, accuracy: 0.01)
        XCTAssertFalse(t.isShown)
        let more = base + [Self.moment(15), Self.moment(18), Self.moment(21), Self.moment(24)]
        let later = try XCTUnwrap(trait(persona(more, texts: [id: text(.high)]), answers: [no]))
        XCTAssertTrue(later.isShown, "two new calls and enough support")
    }

    func testNeverRejectsTheValueForThatPersonInEachSetting() throws {
        let p = persona([1, 4, 7].map { Self.moment($0) }, texts: [id: text()])
        let t = try XCTUnwrap(trait(p, answers: [answer(.never)]))
        XCTAssertEqual(t.state, .rejected)
        XCTAssertFalse(t.isShown)
        let conditioned = persona([1, 4, 7].map { Self.moment($0, setting: .oneOnOne) } + [2, 5, 8].map { Self.moment($0, "order", "path_first") })
        let traits = PersonaTraits.build(conditioned, answers: [answer(.never)])
        XCTAssertEqual(traits.first { $0.value == "answer_first" }?.state, .rejected)
    }

    func testUndoGivesTheTraitBackAsItWas() throws {
        let p = persona([1, 4, 7].map { Self.moment($0) }, texts: [id: text()])
        let before = try XCTUnwrap(trait(p))
        let undone = try XCTUnwrap(trait(p, answers: [answer(nil)]))
        XCTAssertEqual(before, undone)
    }

    // MARK: Properties

    func testANewSupportingCallNeverLowersTheNumberAndANewContradictionNeverRaisesIt() {
        var rng = SystemRandomNumberGenerator()
        let values = ["answer_first", "path_first", "material_before"]
        for _ in 0..<300 {
            let n = Int.random(in: 1...7, using: &rng)
            var ev: [PersonaEvidence] = []
            for i in 0..<n {
                ev.append(Self.moment(Int.random(in: 0...400, using: &rng), "order", values.randomElement(using: &rng)!, call: "x\(i)",
                                      strength: Bool.random(using: &rng) ? .clear : .weak, setting: Bool.random(using: &rng) ? .group : .oneOnOne,
                                      series: ["a", "b", "c"].randomElement(using: &rng)!))
            }
            let rating = PersonaText.Rating.allCases.randomElement(using: &rng)!
            let texts = [id: text(rating)]
            let before = PersonaTraits.number(for: id, in: persona(ev, texts: texts))
            let day = Int.random(in: 0...500, using: &rng)
            let setting: PersonaSetting = Bool.random(using: &rng) ? .group : .oneOnOne
            let plus = PersonaTraits.number(for: id, in: persona(ev + [Self.moment(day, call: "new", setting: setting, series: "a")], texts: texts))
            let minus = PersonaTraits.number(for: id, in: persona(ev + [Self.moment(day, "order", "path_first", call: "new", setting: setting)], texts: texts))
            if let before, let plus { XCTAssertGreaterThanOrEqual(plus + 1e-9, before, "support: \(ev)") }
            if let before, let minus { XCTAssertLessThanOrEqual(minus, before + 1e-9, "contradiction: \(ev)") }
        }
    }

    func testTheSameEvidenceAndAnswersGiveTheSameNumberInAnyOrder() {
        let ev = (1...6).map { Self.moment($0 * 7, $0 % 2 == 0 ? "order" : "evidence", $0 % 2 == 0 ? "answer_first" : "numbers") }
        let a = PersonaTraits.build(persona(ev, texts: [id: text()]), answers: [answer(.no)])
        let b = PersonaTraits.build(persona(ev.reversed(), texts: [id: text()]), answers: [answer(.no)])
        XCTAssertEqual(a, b)
    }

    func testTheRatingAloneCannotShowATraitOfOneCall() {
        for rating in PersonaText.Rating.allCases {
            let t = PersonaTraits.build(persona([Self.moment(1)], texts: [id: text(rating)]), answers: []).first
            XCTAssertFalse(t?.isShown ?? true)
        }
    }

    func testAPersonWithNoProfileHasNoTraits() {
        XCTAssertTrue(PersonaTraits.build(persona([1, 4, 7].map { Self.moment($0) }, texts: [id: text()]), answers: [], doNotProfile: true).isEmpty)
    }

    func testOnlyTwoFreeDimensionsCount() {
        let ev = ["free:a", "free:b", "free:c"].enumerated().flatMap { i, d in (0...(3 - i)).map { Self.moment($0 * 3 + i, d, "yes") } }
        let dims = Set(PersonaTraits.build(persona(ev), answers: []).map(\.dimension))
        XCTAssertEqual(dims, ["free:a", "free:b"])
    }
}
