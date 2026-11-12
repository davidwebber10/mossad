import XCTest
@testable import MossadCore

/// A card says why it matters, and asks one clear question with answers in words.
final class FindingMeaningTests: XCTestCase {
    private let owner = "Dana Lee"
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func call() -> CallRecord {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "", start: base, end: base.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": owner, "them:A": "Riley Park"]
        let lines: [(String, TimeInterval, String)] = [
            ("me", 10, "The analytics plan is yours, Riley."), ("me", 30, "What do you need from me to run it?"),
            ("them", 50, "Mostly the budget sign-off."), ("me", 760, "Let me look at it and get back to you."),
        ]
        r.utterances = lines.map { Utterance(track: $0.0 == "me" ? .me : .them, speakerLabel: "A", start: $0.1, end: $0.1 + 20, text: $0.2) }
        return r
    }

    private func card(_ kind: CoachFinding.Kind, skill: String, why: String? = nil, say: String? = nil, number: String? = nil, usual: String? = nil,
                      at: TimeInterval? = 30) -> CoachFinding {
        CoachFinding(id: "c|\(kind.rawValue)|\(skill)", callID: "c", date: base, kind: kind,
                     text: "You told Riley the analytics plan is his and asked what he needs from you.", skill: skill,
                     quote: "What do you need from me", at: at, number: number, usual: usual, say: say, why: why)
    }

    private var roomGoal: CoachFocus {
        var f = CoachFocus(plan: "In a 1:1, ask before you tell, and let them lead.", why: "You talked 64% in a typical 1:1.", metric: .talkShare,
                           proposed: base.addingTimeInterval(-30 * day), skill: CoachSkill.roomInOneOnOnes.rawValue)
        f.status = .active
        return f
    }

    private func settle(_ review: CoachReview, profile: CoachProfile = CoachProfile(), patterns: [CoachPatternUpdate] = []) -> CoachResult {
        CoachLineRules.settle(CoachResult(review: review, update: CoachProfileUpdate(summary: "", focus: "", patterns: patterns, people: [])),
                              record: call(), owner: owner, profile: profile, measured: CoachMeasured())
    }

    private func review(didWell: CoachNote? = nil, tryNext: CoachNote? = nil) -> CoachReview {
        var r = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        r.didWell = didWell
        r.tryNext = tryNext
        return r
    }

    // MARK: Did well

    func testPraiseThatOnlySaysWhatHappenedIsNoCard() {
        // The owner's real complaint: a "did well" with a skill of its own words and no goal or number.
        XCTAssertNil(FindingMeaning.settle(card(.didWell, skill: "other:hands over ownership"), goals: []))
        // A why of the model does not save it: praise needs a goal, a skill key, or a number.
        XCTAssertNil(FindingMeaning.settle(card(.didWell, skill: "other:hands over ownership", why: "Riley can lead it."), goals: []))
        XCTAssertNil(FindingMeaning.settle(card(.didWell, skill: "pattern:delegates"), goals: []))
        // A number with no usual value is no link.
        XCTAssertNil(FindingMeaning.settle(card(.didWell, skill: "number:talkShare", number: "38%"), goals: []))
    }

    func testPraiseOnTheGoalsSkillSaysItIsThePointOfTheGoal() {
        let goal = roomGoal
        let made = FindingMeaning.settle(card(.didWell, skill: CoachSkill.roomInOneOnOnes.rawValue, why: "This gives Riley room to lead."), goals: [goal])
        XCTAssertEqual(made?.why, "This gives Riley room to lead.", "the model's why first")
        XCTAssertEqual(made?.basis, "Your goal: Room in 1:1s")
        // With no words of the model, the effect of the goal's skill.
        let plain = FindingMeaning.settle(card(.didWell, skill: CoachSkill.roomInOneOnOnes.rawValue), goals: [goal])
        XCTAssertEqual(plain?.why, CoachSkill.roomInOneOnOnes.effect)
        XCTAssertEqual(plain?.basis, "Your goal: Room in 1:1s")
        // A card that names the focus by id is about the goal, also when the goal has ended.
        var ended = goal
        ended.status = .learned
        let byID = FindingMeaning.settle(card(.didWell, skill: "focus:\(goal.id.uuidString)"), goals: [ended])
        XCTAssertEqual(byID?.basis, "Your goal: Room in 1:1s")
        // A goal of its own words: its plan is what the praise stands on.
        var own = goal
        own.skill = "other:hand over ownership"
        let planned = FindingMeaning.settle(card(.didWell, skill: "other:hand over ownership"), goals: [own])
        XCTAssertEqual(planned?.why, "This is what your goal asks for.")
        XCTAssertEqual(planned?.basis, "Your goal: Hand over ownership")
        // A goal that is only proposed is not the owner's goal.
        var proposed = goal
        proposed.status = .proposed
        XCTAssertEqual(FindingMeaning.settle(card(.didWell, skill: CoachSkill.roomInOneOnOnes.rawValue), goals: [proposed])?.basis, "Room in 1:1s")
    }

    func testPraiseWithASkillKeyNamesTheSkillAndItsEffect() {
        let made = FindingMeaning.settle(card(.didWell, skill: CoachSkill.questions.rawValue), goals: [])
        XCTAssertEqual(made?.basis, "Ask before you tell")
        XCTAssertEqual(made?.why, "A question first shows you what the other person needs.")
        XCTAssertEqual(FindingMeaning.settle(card(.didWell, skill: CoachSkill.questions.rawValue, why: "Riley named the budget."), goals: [])?.why,
                       "Riley named the budget.")
        // Each skill key except other has an effect and a cost.
        for skill in CoachSkill.allCases where skill != .other {
            XCTAssertNotNil(skill.effect, skill.rawValue)
            XCTAssertNotNil(skill.cost, skill.rawValue)
        }
    }

    func testPraiseOfANumberAgainstItsUsualValueSaysWhatTheNumberDoes() {
        // "You talked 38% of the time." with its usual value: the number is in the text.
        let made = FindingMeaning.settle(card(.didWell, skill: "number:talkShare", usual: "Usually 55 to 62% in your 1:1s with Riley"), goals: [])
        XCTAssertEqual(made?.why, "Less talk from you leaves the other person room to lead.")
        XCTAssertNil(FindingMeaning.settle(card(.didWell, skill: "number:responseGap", usual: "Usually 0.4 to 0.9 s"), goals: []), "no known effect")
        var number = card(.didWell, skill: "number:longestTurn", usual: "Usually 90 to 150 s in your 1:1s with Riley")
        number.number = "40 s"
        XCTAssertEqual(FindingMeaning.settle(number, goals: [])?.why, "Shorter turns let the others come in.")
        XCTAssertNil(FindingMeaning.settle(number, goals: [])?.basis, "the number shows itself")
        // A measured change in the 1:1 share is a number too.
        var trend = card(.didWell, skill: "progress:oneOnOneShare", at: nil)
        trend.number = "48% in your last 5"
        trend.usual = "62 to 70% in the 10 before"
        XCTAssertEqual(FindingMeaning.settle(trend, goals: [])?.why, "Less talk from you leaves the other person room to lead.")
    }

    // MARK: Did not do, could be better

    func testAMissOrABetterWaySaysWhatItCostsOrWhatToSay() {
        // The words to say are the better way.
        XCTAssertNotNil(FindingMeaning.settle(card(.couldBeBetter, skill: "other:name the risk", say: "My risk here is the date."), goals: []))
        // The model's why is the cost.
        XCTAssertEqual(FindingMeaning.settle(card(.missed, skill: "pattern:history first", why: "The ask came after five minutes."), goals: [])?.why,
                       "The ask came after five minutes.")
        // A skill key gives its cost.
        XCTAssertEqual(FindingMeaning.settle(card(.missed, skill: CoachSkill.commitmentDates.rawValue), goals: [])?.why,
                       "Without a day, nobody can plan on it or tell when it is late.")
        // Neither: no card.
        XCTAssertNil(FindingMeaning.settle(card(.missed, skill: "pattern:history first"), goals: []))
        XCTAssertNil(FindingMeaning.settle(card(.couldBeBetter, skill: "other:name the risk"), goals: []))
        // A number that is not usual in the bad direction.
        var more = card(.couldBeBetter, skill: "number:talkShare", at: nil)
        more.number = "81%"
        more.usual = "Usually 62 to 70% in your 1:1s with Riley"
        XCTAssertEqual(FindingMeaning.settle(more, goals: [])?.why, "More talk from you leaves the other person less room.")
    }

    func testConclusionsTraitsAndGoalOffersPassAsTheyAre() {
        for kind in [CoachFinding.Kind.learning, .trait, .goalOffer] {
            let c = card(kind, skill: "")
            XCTAssertEqual(FindingMeaning.settle(c, goals: []), c)
        }
    }

    // MARK: The deck

    func testAnOlderStoredPraiseCardWithNoLinkIsLeftOutOfTheDeck() {
        var old = review()
        old.version = CoachReview.currentVersion
        old.findings = [card(.didWell, skill: "other:hands over ownership"), card(.couldBeBetter, skill: CoachSkill.answerFirst.rawValue, at: 760)]
        let cards = FindingRules.deck(callID: "c", date: base, review: old, profile: CoachProfile(), now: base.addingTimeInterval(day))
        XCTAssertEqual(cards.map(\.kind), [.couldBeBetter])
        XCTAssertEqual(cards[0].why, CoachSkill.answerFirst.cost, "an older card shows with the why of its skill")
        XCTAssertEqual(cards[0].basis, "Answer first")
        // With the owner's goal on its skill, older praise shows, tied to the goal.
        var profile = CoachProfile()
        profile.foci = [roomGoal]
        old.findings = [card(.didWell, skill: CoachSkill.roomInOneOnOnes.rawValue)]
        let tied = FindingRules.deck(callID: "c", date: base, review: old, profile: profile, now: base.addingTimeInterval(day))
        XCTAssertEqual(tied.first?.basis, "Your goal: Room in 1:1s")
        XCTAssertEqual(tied.first?.why, CoachSkill.roomInOneOnOnes.effect)
    }

    func testTheModelsWhyGoesFromTheReviewToTheCard() {
        let praise = CoachNote(text: "You handed Riley the plan and asked what he needs.", quote: "What do you need from me to run it?", at: 30,
                               skill: CoachSkill.questions.rawValue, why: "Riley named the one thing he needs: the budget.")
        let advice = CoachNote(text: "When you take an item, say the day.", quote: "Let me look at it and get back to you.", at: 760,
                               skill: CoachSkill.commitmentDates.rawValue, why: "Riley cannot plan the budget without a day.")
        let cards = settle(review(didWell: praise, tryNext: advice)).review.findings ?? []
        XCTAssertEqual(cards.map(\.kind), [.couldBeBetter, .didWell])
        XCTAssertEqual(cards[0].why, "Riley cannot plan the budget without a day.")
        XCTAssertEqual(cards[1].why, "Riley named the one thing he needs: the budget.")
        // A why that judges a trend, or is too long, is dropped; the note stays.
        var trend = praise
        trend.why = "You did it better than before."
        let kept = settle(review(didWell: trend)).review
        XCTAssertNotNil(kept.didWell)
        XCTAssertNil(kept.didWell?.why)
        XCTAssertEqual(kept.findings?.first?.why, nil, "the card keeps only the model's why; the deck adds the skill's")
        // Praise of a skill of its own words is no card, with or without a why.
        var other = praise
        other.skill = "other:hands over ownership"
        XCTAssertEqual(settle(review(didWell: other)).review.findings, [])
        XCTAssertNotNil(settle(review(didWell: other)).review.line, "the line still says it")
    }

    func testAPatternCardNeedsItsWhy() {
        let missed = CoachPatternUpdate(name: "History first", kind: .growth, note: "You gave the history before the ask.", result: .missed,
                                        quote: "Let me look at it and get back to you.", at: 1)
        XCTAssertEqual(settle(review(), patterns: [missed]).review.findings, [])
        var told = missed
        told.why = "Riley waited for the ask."
        XCTAssertEqual(settle(review(), patterns: [told]).review.findings?.map(\.why), ["Riley waited for the ask."])
    }

    func testOlderFilesWithNoWhyStillRead() throws {
        let note = try JSONDecoder().decode(CoachNote.self, from: Data(#"{"text":"T","quote":"Q","at":3}"#.utf8))
        XCTAssertNil(note.why)
        let finding = try JSONDecoder().decode(CoachFinding.self, from: Data(#"{"id":"c|did_well|questions","callID":"c","date":0,"kind":"did_well","text":"T","skill":"questions","at":3}"#.utf8))
        XCTAssertNil(finding.why)
        XCTAssertNil(finding.basis)
        // And a newer file reads here with its why.
        let newer = try JSONEncoder().encode(card(.didWell, skill: "questions", why: "W"))
        XCTAssertEqual(try JSONDecoder().decode(CoachFinding.self, from: newer).why, "W")
    }

    // MARK: The question and its answers

    func testEachKindAsksOneQuestionWithAnswersInWords() {
        for kind in [CoachFinding.Kind.didWell, .missed, .couldBeBetter] {
            XCTAssertEqual(kind.question, "Is this feedback useful to you?")
            XCTAssertEqual(kind.yes, "Useful")
            XCTAssertEqual(kind.no, "Not useful")
        }
        for kind in [CoachFinding.Kind.learning, .trait] {
            XCTAssertEqual(kind.question, "Is this true?")
            XCTAssertEqual(kind.yes, "True")
            XCTAssertEqual(kind.no, "Not true")
        }
        XCTAssertEqual(CoachFinding.Kind.goalOffer.yes, "Take it on")
        XCTAssertEqual(CoachFinding.Kind.goalOffer.no, "Not now")
        XCTAssertEqual(CoachFinding.Kind.didWell.title, "You did well")
        XCTAssertEqual(CoachFinding.Kind.didWell.whyNot("You told Riley"), "Why was \u{201C}You told Riley\u{201D} not useful?")
        XCTAssertEqual(CoachFinding.Kind.learning.whyNot("Sam reports to you"), "Why is \u{201C}Sam reports to you\u{201D} not true?")
        for kind in CoachFinding.Kind.all {
            XCTAssertFalse(kind.question.isEmpty)
            XCTAssertFalse(kind.never.isEmpty)
            XCTAssertNotEqual(kind.yes, "Yes")
            XCTAssertNotEqual(kind.no, "No")
        }
    }

    // MARK: Training

    func testNotUsefulOnPraiseLowersThePraiseForThatSkillAndNotItsAdvice() {
        let skill = CoachSkill.questions.rawValue
        var profile = CoachProfile()
        for id in ["a", "b", "d"] {
            var praise = card(.didWell, skill: skill)
            praise.id = "\(id)|did_well|\(skill)"
            praise.callID = id
            profile.answer(praise, .no, at: base)
        }
        let t = profile.training(asOf: base)
        XCTAssertEqual(t.weight(skill), 0, "the advice is not touched")
        XCTAssertEqual(t.weight(skill, praise: true), -3)
        XCTAssertFalse(t.isLowered(skill))
        XCTAssertTrue(t.isLowered(skill, praise: true))
        XCTAssertEqual(t.repeatDays(skill), AdviceRules.repeatDays, "advice comes back as often as before")
        XCTAssertGreaterThan(t.repeatDays(skill, praise: true), AdviceRules.repeatDays)
        XCTAssertTrue(t.isLowered(card(.didWell, skill: skill)))
        XCTAssertFalse(t.isLowered(card(.couldBeBetter, skill: skill)))
        // The model is told so.
        let text = CoachPrompt.trainingText(profile, record: call())
        XCTAssertTrue(text.contains("Praise less useful to them, only for a clear effect: questions."), text)
        XCTAssertFalse(text.contains("Less useful to them"), text)

        // Useful on advice raises the advice, not the praise.
        var advice = CoachProfile()
        advice.answer(card(.couldBeBetter, skill: skill), .yes, at: base)
        XCTAssertEqual(advice.training(asOf: base).weight(skill), 1)
        XCTAssertEqual(advice.training(asOf: base).weight(skill, praise: true), 0)
    }

    func testNeverAgainOnPraiseStopsThePraiseAndLeavesTheAdvice() {
        let skill = CoachSkill.questions.rawValue
        var profile = CoachProfile()
        profile.answer(card(.didWell, skill: skill), .never, at: base)
        let t = profile.training(asOf: base)
        XCTAssertTrue(t.isBlocked(skill, praise: true))
        XCTAssertFalse(t.isBlocked(skill), "the advice of the skill still comes")
        XCTAssertTrue(CoachPrompt.trainingText(profile, record: call()).contains("Never praise again (advice is still welcome): questions."))
        // Never again on advice stops the praise too: the owner does not want the subject.
        var all = CoachProfile()
        all.answer(card(.couldBeBetter, skill: skill), .never, at: base)
        XCTAssertTrue(all.training(asOf: base).isBlocked(skill, praise: true))
        // In a review: the praise is dropped, the advice stays.
        let praise = CoachNote(text: "You asked what he needs.", quote: "What do you need from me to run it?", at: 30, skill: skill)
        let advice = CoachNote(text: "Ask before you tell.", quote: "Let me look at it and get back to you.", at: 760, say: "What do you think?", skill: skill)
        let out = settle(review(didWell: praise), profile: profile)
        XCTAssertNil(out.review.didWell)
        XCTAssertEqual(settle(review(tryNext: advice), profile: profile).review.line?.kind, .tryNext)
    }

    func testThePromptAsksForWhyItMatters() {
        let system = CoachPrompt.system(owner: owner)
        XCTAssertTrue(system.contains("why, in did_well and try_next: why it matters"))
        let schema = LLMCoach.schema
        let props = (schema["properties"] as? [String: Any])
        func fields(_ key: String) -> [String: Any]? {
            guard let any = (props?[key] as? [String: Any])?["anyOf"] as? [[String: Any]] else { return nil }
            return any.first?["properties"] as? [String: Any]
        }
        XCTAssertNotNil(fields("did_well")?["why"])
        XCTAssertNotNil(fields("try_next")?["why"])
    }

    // MARK: Praise of a number or a trend on the meeting page

    private func settle(_ review: CoachReview, profile: CoachProfile, measured: CoachMeasured) -> CoachResult {
        CoachLineRules.settle(CoachResult(review: review, update: CoachProfileUpdate(summary: "", focus: "", patterns: [], people: [])),
                              record: call(), owner: owner, profile: profile, measured: measured)
    }

    private var less: CoachMeasured.Standout {
        CoachMeasured.Standout(id: "talkShare", text: "talked 38% of the time; usually 55 to 62% in your 1:1s with Riley", at: nil, above: false)
    }

    func testNeverPraiseAgainOnANumberStopsItsLineToo() {
        let measured = CoachMeasured(standouts: [less], oneOnOne: true)
        let made = settle(review(), profile: CoachProfile(), measured: measured).review
        XCTAssertEqual(made.line?.kind, .number)
        let praise = try! XCTUnwrap(made.findings?.first)
        XCTAssertEqual(praise.kind, .didWell)
        var profile = CoachProfile()
        profile.answer(praise, .never, at: base)
        let later = settle(review(), profile: profile, measured: measured).review
        XCTAssertNil(later.line, "the meeting page does not show the praise either")
        XCTAssertEqual(later.findings, [])
        // A number that is not praise is advice: "never praise" leaves it.
        let more = CoachMeasured.Standout(id: "talkShare", text: "talked 81% of the time; usually 55 to 62% in your 1:1s with Riley", at: nil, above: true)
        XCTAssertEqual(settle(review(), profile: profile, measured: CoachMeasured(standouts: [more], oneOnOne: true)).review.line?.kind, .number)
    }

    func testNotUsefulOnANumbersPraiseLowersItsLineBehindOtherNews() {
        let praise = CoachNote(text: "You asked what he needs.", quote: "What do you need from me to run it?", at: 30, skill: CoachSkill.questions.rawValue)
        let measured = CoachMeasured(standouts: [less], oneOnOne: true)
        XCTAssertEqual(settle(review(didWell: praise), profile: CoachProfile(), measured: measured).review.line?.kind, .number)
        var profile = CoachProfile()
        for id in ["a", "b"] {
            profile.answer(CoachFinding(id: "\(id)|did_well|number:talkShare", callID: id, date: base, kind: .didWell, text: "T", skill: "number:talkShare",
                                        usual: "U"), .no, at: base)
        }
        XCTAssertEqual(settle(review(didWell: praise), profile: profile, measured: measured).review.line?.kind, .didWell)
    }

    func testNeverPraiseAgainOnATrendStopsItsLine() {
        let trend = CoachTrend(id: "oneOnOneShare", text: "You leave more room in your 1:1s with Riley.", proof: "48% in your last 5; 62 to 70% in the 10 before")
        let measured = CoachMeasured(trend: trend)
        let made = settle(review(), profile: CoachProfile(), measured: measured).review
        XCTAssertEqual(made.line?.kind, .progress)
        let card = try! XCTUnwrap(made.findings?.first)
        var profile = CoachProfile()
        profile.answer(card, .never, at: base)
        XCTAssertNil(settle(review(), profile: profile, measured: measured).review.line)
    }

    // MARK: A reply with no why

    func testAReplyWithNoWhyIsFilledOnlyWhereTheSchemaHasTheNewField() {
        var reply: Any = [
            "did_well": ["text": "T", "quote": "Q", "at_seconds": 3, "skill": "questions", "skill_label": ""],
            "try_next": ["text": "T", "quote": "Q", "at_seconds": 3, "say": "", "skill": "questions", "skill_label": ""],
            "profile": ["patterns": [["name": "N", "kind": "growth", "result": "missed", "note": "N", "quote": "", "at_seconds": NSNull()]], "people": []],
            "focus_proposal": ["plan": "P", "metric": NSNull(), "skill": "questions", "skill_label": ""],
        ]
        let problems = SchemaCheck.fill(&reply, schema: LLMCoach.schema)
        XCTAssertFalse(problems.contains { $0.contains("did_well.why") || $0.contains("try_next.why") || $0.contains("patterns[0].why") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.hasPrefix("focus_proposal") }, "a goal's reason is not new: a reply without it is asked again. \(problems)")
        let object = reply as? [String: Any]
        XCTAssertEqual((object?["did_well"] as? [String: Any])?["why"] as? String, "")
        XCTAssertEqual(((object?["profile"] as? [String: Any])?["patterns"] as? [[String: Any]])?.first?["why"] as? String, "")
        // With its reason the same proposal passes: the reason was the problem.
        var given: Any = ["focus_proposal": ["plan": "P", "why": "W", "metric": NSNull(), "skill": "questions", "skill_label": ""]]
        XCTAssertFalse(SchemaCheck.fill(&given, schema: LLMCoach.schema).contains { $0.hasPrefix("focus_proposal") })
    }

    func testALocalModelThatLeavesOutTheWhyStillGivesAReview() async throws {
        let output: [String: Any] = [
            "quiet": false, "headline": "H",
            "did_well": ["text": "You asked what he needs.", "quote": "What do you need from me to run it?", "at_seconds": 30, "skill": "questions", "skill_label": ""],
            "try_next": NSNull(), "seen_again": NSNull(), "focus_result": NSNull(), "focus_proposal": NSNull(),
            "strengths": [], "improvements": [],
            "meeting_value": ["rating": "medium", "reason": "R", "action": "keep", "suggestion": ""],
            "profile": ["patterns": [["name": "N", "kind": "strength", "result": "did", "note": "N", "quote": "", "at_seconds": NSNull()]], "people": []],
            "questions": [],
        ]
        // As a local server and the Apple model read a reply that came with the schema in the instructions.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        let read = JSONRepair.read(text, schema: LLMCoach.schema, as: LLMCoach.Output.self)
        XCTAssertEqual(read.problems, [])
        XCTAssertNotNil(read.output)
    }

    func testAGoalProposalWithNoReasonIsNotOffered() {
        let blank = CoachFocus(plan: "Ask before you tell.", why: " ", metric: nil, proposed: base, skill: CoachSkill.questions.rawValue)
        let out = CoachLineRules.settle(CoachResult(review: review(), update: CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), proposal: blank),
                                        record: call(), owner: owner, profile: CoachProfile(), measured: CoachMeasured())
        XCTAssertNil(out.proposal)
        XCTAssertTrue(out.dropped.contains { $0.contains("no reason") })
        // An older proposal with no reason in the memory gives no card.
        var profile = CoachProfile()
        profile.propose(blank, at: base)
        var r = review()
        r.findings = [card(.couldBeBetter, skill: CoachSkill.questions.rawValue, say: "What do you need?")]
        XCTAssertFalse(FindingRules.deck(callID: "c", date: base, review: r, profile: profile, now: base.addingTimeInterval(day)).contains { $0.kind == .goalOffer })
    }

    func testAMissOnAGoalOfItsOwnWordsReadsAsOneSentence() {
        var own = roomGoal
        own.skill = "other:hand over ownership"
        let miss = FindingMeaning.settle(card(.missed, skill: "other:hand over ownership"), goals: [own])
        XCTAssertEqual(miss?.why, "Your goal asks for this, and the chance passed.")
        XCTAssertEqual(miss?.basisIsGoal, true)
        XCTAssertEqual(FindingMeaning.settle(card(.didWell, skill: CoachSkill.questions.rawValue), goals: [])?.basisIsGoal, false)
    }
}
