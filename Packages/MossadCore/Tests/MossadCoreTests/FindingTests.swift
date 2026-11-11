import XCTest
@testable import MossadCore

/// The coach's findings as cards: each with proof, a few for each call, gone after two weeks, and answers that
/// train the coach.
final class FindingTests: XCTestCase {
    private let owner = "Dana Lee"
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    // MARK: Helpers

    private func call(_ id: String = "c", day n: Double = 0) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: base.addingTimeInterval(n * day), end: base.addingTimeInterval(n * day + 1800), status: .written)
        r.speakerNames = ["me:A": owner, "them:A": "Sam Carter"]
        let lines: [(String, TimeInterval, String)] = [
            ("me", 10, "I will send the forecast to finance."), ("them", 40, "When can we see the forecast?"),
            ("me", 760, "Let me look at it and get back to you."), ("me", 900, "My read is that the vendor price holds until March."),
            ("me", 1200, "So what I am hearing is that the date moved."), ("me", 1500, "I went on for a long time about the history there."),
        ]
        r.utterances = lines.map { Utterance(track: $0.0 == "me" ? .me : .them, speakerLabel: "A", start: $0.1, end: $0.1 + 20, text: $0.2) }
        return r
    }

    private let dates = CoachSkill.commitmentDates.rawValue
    private let risk = "other:name the risk"

    private var advice: CoachNote {
        CoachNote(text: "When you take an item, say the day.", quote: "Let me look at it and get back to you.", at: 760, say: "I will send it by Friday.", skill: dates)
    }

    private var praise: CoachNote { CoachNote(text: "You named the risk.", quote: "My read is that the vendor price holds", at: 900, skill: risk) }

    private func review(tryNext: CoachNote? = nil, didWell: CoachNote? = nil) -> CoachReview {
        var r = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        r.tryNext = tryNext
        r.didWell = didWell
        return r
    }

    private func settle(_ review: CoachReview, _ record: CallRecord? = nil, profile: CoachProfile = CoachProfile(), measured: CoachMeasured = CoachMeasured(),
                        patterns: [CoachPatternUpdate] = [], proposal: CoachFocus? = nil) -> CoachResult {
        CoachLineRules.settle(CoachResult(review: review, update: CoachProfileUpdate(summary: "", focus: "", patterns: patterns, people: []), proposal: proposal),
                              record: record ?? call(), owner: owner, profile: profile, measured: measured)
    }

    private func card(_ kind: CoachFinding.Kind = .couldBeBetter, skill: String? = nil, callID: String = "c", day n: Double = 0, at: TimeInterval? = 760) -> CoachFinding {
        let skill = skill ?? dates
        return CoachFinding(id: "\(callID)|\(kind.rawValue)|\(skill)", callID: callID, date: base.addingTimeInterval(n * day), kind: kind, text: "T", skill: skill,
                       quote: "Let me look at it", at: at)
    }

    private func question(_ statement: String = "Sam reports to you.", callID: String = "c", at: TimeInterval? = 40) -> CoachQuestion {
        CoachQuestion(statement: statement, kind: .relationship, evidence: "When can we see the forecast?", callID: callID, at: at, asked: base)
    }

    private func deck(_ review: CoachReview, _ profile: CoachProfile = CoachProfile(), callID: String = "c", day n: Double = 0, now: Double = 1) -> [CoachFinding] {
        FindingRules.deck(callID: callID, date: base.addingTimeInterval(n * day), review: review, profile: profile, now: base.addingTimeInterval(now * day))
    }

    // MARK: Cards and proof

    func testTheLineAndTheNotesOfAReviewBecomeCardsWithTheirProof() {
        let out = settle(review(tryNext: advice, didWell: praise))
        let cards = out.review.findings ?? []
        XCTAssertEqual(cards.map(\.kind), [.couldBeBetter, .didWell], "the line first")
        XCTAssertEqual(cards[0].text, "When you take an item, say the day.")
        XCTAssertEqual(cards[0].quote, "Let me look at it and get back to you.")
        XCTAssertEqual(cards[0].at, 760)
        XCTAssertEqual(cards[0].say, "I will send it by Friday.")
        XCTAssertEqual(cards[0].skill, dates)
        XCTAssertEqual(cards[0].callID, "c")
        XCTAssertEqual(cards[1].at, 900)
        XCTAssertTrue(cards.allSatisfy(\.hasProof))
        XCTAssertEqual(Set(cards.map(\.id)).count, 2)
    }

    func testACardWithoutProofIsNeverMade() {
        // The quote is not in the owner's lines: the note is dropped, and so is its card.
        var bad = advice
        bad.quote = "Words that nobody said in this call."
        XCTAssertEqual(settle(review(tryNext: bad)).review.findings, [])
        // A finding with no moment and no usual value has no proof.
        XCTAssertFalse(CoachFinding(id: "x", callID: "c", date: base, kind: .couldBeBetter, text: "T", skill: dates, number: "2 of 9 commitments").hasProof)
        XCTAssertTrue(CoachFinding(id: "x", callID: "c", date: base, kind: .couldBeBetter, text: "You talked 81% of the time.", skill: "number:talkShare",
                              usual: "Usually 62 to 70% in your 1:1s with Sam").hasProof)
        // A conclusion with no moment is not a card. It still waits in Settings.
        var profile = CoachProfile()
        profile.ask([question(at: nil)])
        XCTAssertEqual(deck(review(), profile), [])
        XCTAssertEqual(profile.openQuestions.count, 1)
    }

    func testANumberThatIsNotUsualIsACardOnlyWhenItsDirectionSaysSomething() {
        let more = CoachMeasured.Standout(id: "talkShare", text: "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam", at: nil, above: true)
        let shorter = CoachMeasured.Standout(id: "longestTurn", text: "longest turn was 40 s; usually 90 to 150 s in your 1:1s with Sam", at: 1500, above: false)
        let gap = CoachMeasured.Standout(id: "responseGap", text: "answered after 2.1 s; usually 0.4 to 0.9 s", at: nil, above: true)
        let cards = settle(review(), measured: CoachMeasured(standouts: [more, shorter, gap], oneOnOne: true)).review.findings ?? []
        XCTAssertEqual(cards.map(\.kind), [.couldBeBetter, .didWell], "a slower answer is neither good nor bad")
        XCTAssertEqual(cards[0].text, "You talked 81% of the time.")
        XCTAssertEqual(cards[0].usual, "Usually 62 to 70% in your 1:1s with Sam")
        XCTAssertNil(cards[0].at)
        XCTAssertTrue(cards[0].hasProof, "a number with its usual value is proof")
        XCTAssertEqual(cards[1].at, 1500)
        XCTAssertEqual(cards[1].skill, "number:longestTurn")
        // In a group, more or less talk is not a judgment.
        XCTAssertEqual(settle(review(), measured: CoachMeasured(standouts: [more], oneOnOne: false)).review.findings, [])
        // A number with no known direction is no card.
        var unknown = more
        unknown.above = nil
        XCTAssertEqual(settle(review(), measured: CoachMeasured(standouts: [unknown], oneOnOne: true)).review.findings, [])
    }

    func testAPatternThatTheCallShowedIsACardWithTheOwnersWords() {
        let missed = CoachPatternUpdate(name: "Long history first", kind: .growth, note: "You gave the history before the ask.", result: .missed,
                                        quote: "I went on for a long time about the history", at: 1)
        let did = CoachPatternUpdate(name: "Reflects back", kind: .strength, note: "You said back what you heard.", result: .did,
                                     quote: "So what I am hearing is that the date moved.", at: 1)
        let unproven = CoachPatternUpdate(name: "Vague", kind: .growth, note: "N", result: .missed, quote: "Nobody said this at all here.", at: 3)
        let trend = CoachPatternUpdate(name: "Trend", kind: .growth, note: "You did it again, a third time.", result: .missed, quote: "I will send the forecast to finance.", at: 3)
        let cards = settle(review(tryNext: advice), patterns: [missed, did, unproven, trend]).review.findings ?? []
        XCTAssertEqual(cards.map(\.kind), [.couldBeBetter, .missed, .didWell])
        XCTAssertEqual(cards[1].text, "You gave the history before the ask.")
        XCTAssertEqual(cards[1].at, 1500, "the time is where code found the words")
        XCTAssertEqual(cards[1].skill, "pattern:long history first")
    }

    func testACallGivesTwoCardsAtMostAndAnAnswerMakesNoRoomForAThird() {
        let patterns = (0..<6).map { i in
            CoachPatternUpdate(name: "P\(i)", kind: .growth, note: "Note \(i).", result: .missed,
                               quote: ["I will send the forecast to finance.", "So what I am hearing is that the date moved.", "I went on for a long time about the history there.",
                                       "My read is that the vendor price holds until March.", "Let me look at it and get back to you.", "I will send the forecast"][i], at: 1)
        }
        let made = settle(review(tryNext: advice), patterns: patterns).review
        var profile = CoachProfile()
        profile.ask([question()])
        let cards = deck(made, profile)
        XCTAssertEqual(cards.count, FindingRules.perCall)
        XCTAssertEqual(FindingRules.perCall, 2)
        XCTAssertEqual(cards.map(\.kind), [.couldBeBetter, .learning], "the line, then what the coach asks")
        profile.answer(cards[0], .yes, at: base.addingTimeInterval(day))
        let left = deck(made, profile)
        XCTAssertEqual(left.map(\.id), Array(cards.dropFirst().map(\.id)), "the third card does not move up")
    }

    func testUnansweredCardsGoAfterTwoWeeks() {
        let made = settle(review(tryNext: advice)).review
        XCTAssertEqual(deck(made, now: 13.9).count, 1)
        XCTAssertEqual(deck(made, now: 14.1).count, 0)
        XCTAssertEqual(FindingRules.expiryDays, 14)
        // An older review, from before the cards, gives its line as a card.
        var old = review(tryNext: advice)
        old.version = CoachReview.currentVersion
        old.line = CoachLine(kind: .tryNext, note: advice)
        XCTAssertNil(old.findings)
        XCTAssertEqual(deck(old).map(\.kind), [.couldBeBetter])
    }

    func testTheDeckOfAllCallsHasTheNewestCallFirst() {
        let a = settle(review(tryNext: advice), call("a", day: 0)).review
        let b = settle(review(didWell: praise), call("b", day: 3)).review
        let old = settle(review(didWell: praise), call("z", day: -20)).review
        let all = FindingRules.deck(reviews: [(callID: "z", date: base.addingTimeInterval(-20 * day), review: old), (callID: "a", date: base, review: a),
                                              (callID: "b", date: base.addingTimeInterval(3 * day), review: b)],
                                    profile: CoachProfile(), now: base.addingTimeInterval(4 * day))
        XCTAssertEqual(all.map(\.callID), ["b", "a"])
    }

    // MARK: Learnings

    func testYesOnALearningMakesItAFact() {
        var profile = CoachProfile()
        profile.ask([question()])
        let card = deck(review(), profile)[0]
        XCTAssertEqual(card.kind, .learning)
        XCTAssertEqual(card.text, "Sam reports to you.")
        XCTAssertEqual(card.at, 40)
        profile.answer(card, .yes, at: base.addingTimeInterval(day))
        XCTAssertEqual(profile.facts.map(\.text), ["Sam reports to you."])
        XCTAssertEqual(profile.questions[0].status, .confirmed)
        XCTAssertEqual(deck(review(), profile), [])
    }

    func testNoOnALearningDropsThatOneCardAndIsNotNeverAgain() {
        var profile = CoachProfile()
        profile.ask([question()])
        profile.answer(deck(review(), profile)[0], .no, at: base.addingTimeInterval(day))
        XCTAssertEqual(deck(review(), profile), [], "the card is gone")
        XCTAssertTrue(profile.facts.isEmpty)
        XCTAssertTrue(profile.openQuestions.isEmpty, "it does not wait for an answer")
        XCTAssertNotEqual(profile.questions[0].status, .rejected, "a plain no is not \"not true for good\"")
        XCTAssertTrue(CoachPrompt.questionsText(profile, now: base.addingTimeInterval(2 * day)).contains("Not confirmed"))
        XCTAssertFalse(CoachPrompt.questionsText(profile, now: base.addingTimeInterval(2 * day)).contains("Not true"))
        // The coach does not ask it again at once.
        var again = question(callID: "d")
        again.asked = base.addingTimeInterval(5 * day)
        profile.ask([again])
        XCTAssertEqual(profile.questions.count, 1)
        XCTAssertTrue(profile.openQuestions.isEmpty)
        // After the days of the repeat rule, another call can bring it back, one card.
        again.asked = base.addingTimeInterval(40 * day)
        profile.ask([again])
        XCTAssertEqual(profile.questions.count, 1)
        XCTAssertEqual(profile.openQuestions.map(\.callID), ["d"])
    }

    func testNeverAgainOnALearningBlocksItForGoodAndCanBeTakenBack() {
        var profile = CoachProfile()
        profile.ask([question()])
        let card = deck(review(), profile)[0]
        profile.answer(card, .never, at: base.addingTimeInterval(day))
        XCTAssertEqual(profile.questions[0].status, .rejected)
        XCTAssertTrue(CoachPrompt.questionsText(profile, now: base.addingTimeInterval(2 * day)).contains("Not true:\n- Sam reports to you."))
        var again = question(callID: "d")
        again.asked = base.addingTimeInterval(400 * day)
        profile.ask([again])
        XCTAssertEqual(profile.questions.count, 1, "never asked again")
        XCTAssertEqual(profile.neverAgain.map(\.text), ["Sam reports to you."])
        // Settings > Coach takes it back.
        profile.takeBack(card.id, at: base.addingTimeInterval(2 * day))
        XCTAssertEqual(profile.neverAgain, [])
        XCTAssertEqual(profile.questions[0].status, .open)
        XCTAssertEqual(deck(review(), profile, now: 3).map(\.id), [card.id])
    }

    // MARK: Weights

    func testYesAndNoMoveTheWeightOfASkillALittle() {
        var profile = CoachProfile()
        XCTAssertEqual(profile.training(asOf: base).weight(dates), 0)
        profile.answer(card(callID: "a"), .yes, at: base)
        XCTAssertEqual(profile.training(asOf: base).weight(dates), 1)
        profile.answer(card(callID: "b"), .no, at: base)
        profile.answer(card(callID: "d"), .no, at: base)
        XCTAssertEqual(profile.training(asOf: base).weight(dates), -1)
        XCTAssertFalse(profile.training(asOf: base).isLowered(dates), "one no more than yes changes nothing yet")
        profile.answer(card(callID: "e"), .no, at: base)
        let t = profile.training(asOf: base)
        XCTAssertEqual(t.weight(dates), -2)
        XCTAssertTrue(t.isLowered(dates), "a few no's lower it")
        XCTAssertEqual(t.repeatDays(dates), 60)
        XCTAssertEqual(t.repeatDays(risk), AdviceRules.repeatDays)
        XCTAssertEqual(t.weight(risk), 0, "another skill is not touched")
        // Many no's never block a skill by themselves.
        for i in 0..<8 { profile.answer(card(callID: "n\(i)"), .no, at: base) }
        let low = profile.training(asOf: base)
        XCTAssertEqual(low.weight(dates), -CoachTraining.limit)
        XCTAssertFalse(low.isBlocked(dates))
        XCTAssertEqual(low.repeatDays(dates), 75)
        // An answer from long ago does not count.
        XCTAssertEqual(profile.training(asOf: base.addingTimeInterval(120 * day)).weight(dates), 0)
        // The same card answered again is one answer.
        var one = CoachProfile()
        one.answer(card(), .no, at: base)
        one.answer(card(), .no, at: base.addingTimeInterval(60))
        XCTAssertEqual(one.training(asOf: base).weight(dates), -1)
    }

    func testALoweredSkillWaitsLongerAndStandsBehindOtherNews() {
        var profile = CoachProfile()
        for id in ["a", "b"] { profile.answer(card(callID: id, day: -41), .no, at: base.addingTimeInterval(-40 * day)) }
        profile.advice = [CoachAdvice(callID: "old", date: base.addingTimeInterval(-40 * day), kind: .tryNext, skill: dates, text: "T", at: 5)]
        // 40 days after the line: with no answers the advice could come again; with two no's it waits 60 days.
        XCTAssertEqual(settle(review(tryNext: advice)).review.line?.kind, .tryNext)
        let held = settle(review(tryNext: advice), profile: profile)
        XCTAssertNil(held.review.tryNext)
        XCTAssertNotNil(held.review.seenAgain, "the call is counted, and the advice is not said")
        // With nothing in the log, lowered advice is still said, after the other news of the call.
        var low = CoachProfile()
        for id in ["a", "b"] { low.answer(card(callID: id), .no, at: base) }
        XCTAssertEqual(settle(review(tryNext: advice, didWell: praise), profile: low).review.line?.kind, .didWell)
        XCTAssertEqual(settle(review(tryNext: advice), profile: low).review.line?.kind, .tryNext, "lower is not blocked")
        // The model is told the longer wait too.
        XCTAssertTrue(CoachPrompt.earlierAdviceText(profile, record: call()).contains(dates))
        XCTAssertFalse(CoachPrompt.earlierAdviceText({ var p = profile; p.answers = []; return p }(), record: call()).contains(dates))
    }

    func testNeverAgainBlocksTheSkillForGoodAndCanBeTakenBack() {
        var profile = CoachProfile()
        let made = settle(review(tryNext: advice, didWell: praise)).review
        let first = deck(made, profile)[0]
        profile.answer(first, .never, at: base.addingTimeInterval(day))
        XCTAssertTrue(profile.training(asOf: base).isBlocked(dates))
        XCTAssertEqual(deck(made, profile).map(\.kind), [.didWell])
        // A later call: the note is dropped, with the reason, and no card is made.
        let later = settle(review(tryNext: advice, didWell: praise), call("d", day: 200), profile: profile)
        XCTAssertNil(later.review.tryNext)
        XCTAssertEqual(later.review.line?.kind, .didWell)
        XCTAssertEqual(later.review.findings?.map(\.kind), [.didWell])
        XCTAssertTrue(later.dropped.contains { $0.contains("never again") })
        XCTAssertTrue(CoachPrompt.trainingText(profile, record: call("d", day: 200)).contains("Never again"))
        XCTAssertTrue(CoachPrompt.trainingText(profile, record: call("d", day: 200)).contains(dates))
        XCTAssertEqual(profile.neverAgain.map(\.skill), [dates])
        // A blocked number is not a line and not a card.
        var numbers = CoachProfile()
        numbers.answer(card(.couldBeBetter, skill: "number:talkShare"), .never, at: base)
        let more = CoachMeasured.Standout(id: "talkShare", text: "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam", at: nil, above: true)
        let quiet = settle(review(), profile: numbers, measured: CoachMeasured(standouts: [more], oneOnOne: true)).review
        XCTAssertNil(quiet.line)
        XCTAssertEqual(quiet.findings, [])
        // Taken back in Settings: the skill is coached again.
        profile.takeBack(first.id, at: base.addingTimeInterval(2 * day))
        XCTAssertFalse(profile.training(asOf: base).isBlocked(dates))
        XCTAssertEqual(settle(review(tryNext: advice), call("d", day: 200), profile: profile).review.line?.kind, .tryNext)
    }

    // MARK: Goal offers

    func testAGoalOfferNeedsAMomentAndYesAcceptsTheFocus() {
        let focus = CoachFocus(plan: "When you take an item, say the day.", why: "Three items left with no day.", metric: nil, proposed: base, skill: dates)
        var profile = CoachProfile()
        profile.propose(focus, at: base)
        let made = settle(review(tryNext: advice, didWell: praise)).review
        let cards = deck(made, profile)
        XCTAssertEqual(cards.map(\.kind), [.goalOffer, .didWell], "the offer stands for the advice about its skill")
        XCTAssertEqual(cards[0].text, "When you take an item, say the day.")
        XCTAssertEqual(cards[0].detail, "Three items left with no day.")
        XCTAssertEqual(cards[0].at, 760, "the moment of this call that shows it")
        // With no moment for its skill in the call, there is no card. The proposal stays where it is today.
        XCTAssertEqual(deck(settle(review(didWell: praise)).review, profile).map(\.kind), [.didWell])
        // Another call's deck does not offer it.
        XCTAssertEqual(deck(made, profile, callID: "other", day: 1, now: 2).filter { $0.kind == .goalOffer }, [])

        var yes = profile
        yes.answer(cards[0], .yes, at: base.addingTimeInterval(day))
        XCTAssertEqual(yes.activeFocus?.id, profile.proposedFocus?.id)
        var no = profile
        no.answer(cards[0], .no, at: base.addingTimeInterval(day))
        XCTAssertNil(no.proposedFocus)
        XCTAssertNil(no.activeFocus)
        XCTAssertFalse(no.training(asOf: base).isGoalBlocked(dates))
        var never = profile
        never.answer(cards[0], .never, at: base.addingTimeInterval(day))
        XCTAssertTrue(never.training(asOf: base).isGoalBlocked(dates))
        XCTAssertFalse(never.training(asOf: base).isBlocked(dates), "advice about it can still come")
        let later = settle(review(), call("d", day: 60), profile: never, proposal: CoachFocus(plan: "P", why: "W", metric: nil, proposed: base, skill: dates))
        XCTAssertNil(later.proposal, "the coach does not offer this goal again")
        XCTAssertNotNil(settle(review(), call("d", day: 60), profile: no, proposal: CoachFocus(plan: "P", why: "W", metric: nil, proposed: base, skill: dates)).proposal)
    }

    // MARK: Undo, and the reason for a no

    func testUndoPutsTheCardBackAsItWas() {
        let focus = CoachFocus(plan: "When you take an item, say the day.", why: "W", metric: nil, proposed: base, skill: dates)
        var profile = CoachProfile()
        profile.propose(focus, at: base)
        profile.ask([question()])
        let made = settle(review(tryNext: advice, didWell: praise)).review
        let before = profile
        let cards = deck(made, profile)
        XCTAssertEqual(cards.map(\.kind), [.goalOffer, .learning], "two cards for a call")
        let praised = deck(settle(review(didWell: praise)).review)
        XCTAssertEqual(praised.map(\.kind), [.didWell])
        for (card, verdict) in zip(cards + praised, [FindingVerdict.yes, .yes, .no]) {
            let made = card.kind == .didWell ? settle(review(didWell: praise)).review : made
            let cards = card.kind == .didWell ? praised : cards
            var p = card.kind == .didWell ? CoachProfile() : profile
            p.answer(card, verdict, at: base.addingTimeInterval(day))
            XCTAssertFalse(deck(made, p).contains(card))
            p.takeBack(card.id, at: base.addingTimeInterval(day + 5))
            XCTAssertEqual(deck(made, p, now: 2), cards, "\(card.kind.rawValue)")
            XCTAssertEqual(p.facts, card.kind == .didWell ? [] : before.facts)
            XCTAssertEqual(p.activeFocus, nil)
            XCTAssertEqual(p.training(asOf: base).weight(risk), 0)
            XCTAssertNil(p.answer(to: card.id), "the answer is taken back")
        }
        profile.answer(cards[1], .no, at: base.addingTimeInterval(day))
        profile.takeBack(cards[1].id, at: base.addingTimeInterval(day + 5))
        XCTAssertEqual(profile.openQuestions.count, 1)
    }

    func testTheReasonForANoIsGuidanceForThatCard() {
        var profile = CoachProfile()
        let made = settle(review(tryNext: advice)).review
        let card = deck(made, profile)[0]
        profile.answer(card, .no, at: base.addingTimeInterval(day))
        profile.explain(card.id, note: "  I gave the day in the email after the call. ", at: base.addingTimeInterval(day + 30))
        XCTAssertEqual(profile.answer(to: card.id)?.note, "I gave the day in the email after the call.")
        XCTAssertEqual(profile.guidance.count, 1)
        XCTAssertEqual(profile.guidance[0].finding, card.id)
        XCTAssertEqual(profile.guidance[0].skill, dates)
        XCTAssertTrue(profile.guidance[0].text.contains("I gave the day in the email after the call."))
        XCTAssertTrue(profile.guidance[0].text.contains("When you take an item, say the day."), "the card it is about")
        // A second reason for the same card replaces the first.
        profile.explain(card.id, note: "Dates go in the email.", at: base.addingTimeInterval(day + 60))
        XCTAssertEqual(profile.guidance.count, 1)
        XCTAssertTrue(profile.guidance[0].text.contains("Dates go in the email."))
        XCTAssertTrue(CoachPrompt.user(record: call("d", day: 5), owner: owner, profile: profile).contains("Dates go in the email."))
        // An empty line saves nothing, and a card with no answer takes no reason.
        var other = CoachProfile()
        other.explain(card.id, note: "Why", at: base)
        XCTAssertTrue(other.guidance.isEmpty)
        // Undo of the answer takes its reason with it.
        profile.takeBack(card.id, at: base.addingTimeInterval(2 * day))
        XCTAssertTrue(profile.guidance.isEmpty)
    }

    func testTheLineAboutANoNamesItsCardInAFewWords() {
        XCTAssertEqual(FindingRules.shortTitle("When you take an item, say the day."), "When you take an item, say\u{2026}")
        XCTAssertEqual(FindingRules.shortTitle("Sam reports to you."), "Sam reports to you")
        XCTAssertEqual(FindingRules.shortTitle("You named the risk."), "You named the risk")
    }

    // MARK: The prompt

    func testThePromptSaysWhatTheOwnerAnswered() {
        var profile = CoachProfile()
        for id in ["a", "b"] { profile.answer(card(.didWell, skill: risk, callID: id), .yes, at: base) }
        for id in ["a", "b"] { profile.answer(card(callID: id), .no, at: base) }
        profile.answer(card(.missed, skill: CoachSkill.interruptions.rawValue), .never, at: base)
        profile.answer(CoachFinding(id: "g", callID: "c", date: base, kind: .goalOffer, text: "P", skill: CoachSkill.longTurns.rawValue, at: 1, focusID: UUID()), .never, at: base)
        let text = CoachPrompt.trainingText(profile, record: call("d", day: 1))
        XCTAssertTrue(text.contains("Useful to them: other, skill_label \"name the risk\""), text)
        XCTAssertTrue(text.contains("Less useful to them"), text)
        XCTAssertTrue(text.contains("commitment-dates"), text)
        XCTAssertTrue(text.contains("Never again"), text)
        XCTAssertTrue(text.contains("interruptions"), text)
        XCTAssertTrue(text.contains("Never offer as a focus: long-turns"), text)
        XCTAssertTrue(CoachPrompt.user(record: call("d", day: 1), owner: owner, profile: profile).contains(text))
        XCTAssertEqual(CoachPrompt.trainingText(CoachProfile(), record: call()), "")
        XCTAssertFalse(CoachPrompt.user(record: call(), owner: owner, profile: CoachProfile()).contains("answered your findings"))
    }

    func testAConfirmedPreferenceGoesToTheModel() {
        var profile = CoachProfile()
        var q = question("You hold back dates in budget calls on purpose.")
        q.kind = .preference
        profile.ask([q])
        profile.answer(deck(review(), profile)[0], .yes, at: base)
        XCTAssertTrue(CoachPrompt.user(record: call("d", day: 1), owner: owner, profile: profile).contains("You hold back dates in budget calls on purpose."))
    }

    // MARK: Files and devices

    func testOldFilesDecodeAndAnEntryOfALaterBuildIsLeftOut() throws {
        let old = #"{"summary":"S","questions":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","statement":"Sam reports to you.","kind":"relationship","evidence":"E","status":"open","asked":"2026-10-01T10:00:00Z","updated":"2026-10-01T10:00:00Z"}],"facts":[{"kind":"role","text":"Head of data"}],"guidance":[{"text":"G","date":"2026-10-01T10:00:00Z"}]}"#
        let p = try JSONDecoder.coach.decode(CoachProfile.self, from: Data(old.utf8))
        XCTAssertEqual(p.answers, [])
        XCTAssertNil(p.questions[0].dismissed)
        XCTAssertNil(p.facts[0].person)
        XCTAssertNil(p.guidance[0].finding)
        let review = try JSONDecoder.coach.decode(CoachReview.self, from: Data(#"{"headline":"H","overview":"","strengths":[],"improvements":[]}"#.utf8))
        XCTAssertNil(review.findings)
        // An answer with a verdict or a kind from a later build does not empty the log.
        let later = #"{"answers":[{"id":"a","callID":"c","kind":"did_well","skill":"s","text":"T","verdict":"yes","date":"2026-10-01T10:00:00Z"},{"id":"b","callID":"c","kind":"some_new_kind","skill":"s","text":"T","verdict":"maybe","date":"2026-10-01T10:00:00Z"},{"id":7}]}"#
        let q = try JSONDecoder.coach.decode(CoachProfile.self, from: Data(later.utf8))
        XCTAssertEqual(q.answers.map(\.id), ["a", "b"])
        XCTAssertNil(q.answers[1].verdict)
        XCTAssertEqual(q.training(asOf: base).weight("s"), 1)
        // A card of a kind from a later build is not shown, and the review reads.
        let cards = #"{"headline":"H","overview":"","strengths":[],"improvements":[],"version":3,"findings":[{"id":"x","callID":"c","date":"2026-10-01T10:00:00Z","kind":"some_new_kind","text":"T","skill":"s","at":4}]}"#
        let r = try JSONDecoder.coach.decode(CoachReview.self, from: Data(cards.utf8))
        XCTAssertEqual(r.findings?.count, 1)
        XCTAssertEqual(FindingRules.deck(callID: "c", date: base, review: r, profile: CoachProfile(), now: base), [])
        // The new memory round-trips.
        var full = CoachProfile()
        full.ask([question()])
        full.answer(card(), .no, at: base)
        full.explain(card().id, note: "Why", at: base)
        XCTAssertEqual(try JSONDecoder.coach.decode(CoachProfile.self, from: JSONEncoder.coach.encode(full)), full)
    }

    func testAnswersMergeBetweenDevicesAndTheNewerWins() {
        var mac = CoachProfile(), phone = CoachProfile()
        mac.answer(card(callID: "a"), .yes, at: base)
        phone.answer(card(callID: "a"), .no, at: base.addingTimeInterval(60))
        phone.answer(card(callID: "b"), .never, at: base)
        mac.answer(card(callID: "d"), .no, at: base)
        // Undo on the Mac, later than the phone's copy of the same answer.
        phone.answer(card(callID: "e"), .yes, at: base)
        mac.answer(card(callID: "e"), .yes, at: base)
        mac.takeBack(card(callID: "e").id, at: base.addingTimeInterval(120))
        for merged in [mac.merged(with: phone), phone.merged(with: mac, takeCoaching: true)] {
            XCTAssertEqual(merged.answer(to: card(callID: "a").id)?.verdict, .no)
            XCTAssertEqual(merged.answer(to: card(callID: "b").id)?.verdict, .never)
            XCTAssertEqual(merged.answer(to: card(callID: "d").id)?.verdict, .no)
            XCTAssertNil(merged.answer(to: card(callID: "e").id), "the later undo holds")
            XCTAssertTrue(merged.training(asOf: base).isBlocked(dates))
        }
        // A no on a learning on the phone reaches the Mac.
        var asked = CoachProfile()
        asked.ask([question()])
        var answered = asked
        answered.answer(FindingRules.deck(callID: "c", date: base, review: review(), profile: asked, now: base)[0], .no, at: base.addingTimeInterval(60))
        XCTAssertTrue(asked.merged(with: answered).openQuestions.isEmpty)
    }

    func testTheAnswersOfACallAreSavedNextToItsReview() throws {
        let paths = Paths(root: tempDirectory())
        defer { try? FileManager.default.removeItem(at: paths.root) }
        for id in ["a", "b"] { try FileManager.default.createDirectory(at: paths.callDirectory(id), withIntermediateDirectories: true) }
        var profile = CoachProfile()
        profile.answer(card(callID: "a"), .yes, at: base)
        profile.answer(card(.didWell, skill: risk, callID: "a"), .no, at: base)
        profile.answer(card(callID: "b"), .no, at: base)
        profile.answer(card(callID: "gone"), .no, at: base)
        XCTAssertTrue(FindingStore.mirror(profile.answers, callID: "a", paths: paths))
        let saved = try XCTUnwrap(CallFindings.load(in: paths.callDirectory("a")))
        XCTAssertEqual(saved.answers.map(\.verdict), [.yes, .no])
        XCTAssertNil(CallFindings.load(in: paths.callDirectory("b")), "only the call of the answer is written")
        XCTAssertFalse(FindingStore.mirror(profile.answers, callID: "gone", paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("gone").path), "a deleted meeting's folder does not come back")
        XCTAssertFalse(FindingStore.mirror(profile.answers, callID: "a", paths: paths), "nothing new, nothing written")
        profile.takeBack(card(callID: "a").id, at: base.addingTimeInterval(60))
        XCTAssertTrue(FindingStore.mirror(profile.answers, callID: "a", paths: paths))
        XCTAssertEqual(CallFindings.load(in: paths.callDirectory("a"))?.answers.compactMap(\.verdict), [.no])
    }

    func testADeletedMeetingKeepsTheOwnersAnswersOnEachDevice() {
        var profile = CoachProfile()
        profile.answer(card(callID: "a"), .no, at: base)
        profile.answer(card(.didWell, skill: risk, callID: "a"), .never, at: base)
        let other = profile
        profile.forget(callID: "a")
        XCTAssertEqual(profile.answers.map(\.verdict), [.no, .never], "an answer is the owner's signal about the coaching")
        XCTAssertEqual(profile.training(asOf: base).weight(dates), -1)
        XCTAssertTrue(profile.training(asOf: base).isBlocked(risk))
        // The other device has the same answers: a merge brings nothing back and takes nothing away.
        XCTAssertEqual(profile.merged(with: other).answers, profile.answers)
    }

    // MARK: Review fixes

    func testUndoOfAYesOnAGoalGivesBackTheFocusItReplaced() {
        var profile = CoachProfile()
        let old = CoachFocus(plan: "Leave room in your 1:1s.", why: "W", metric: nil, proposed: base.addingTimeInterval(-30 * day), skill: CoachSkill.longTurns.rawValue)
        profile.propose(old, at: old.proposed)
        profile.acceptFocus(old.id, plan: nil, at: old.proposed)
        let offer = CoachFocus(plan: "When you take an item, say the day.", why: "W", metric: nil, proposed: base, skill: dates)
        profile.propose(offer, at: base)
        let made = settle(review(tryNext: advice)).review
        let card = deck(made, profile)[0]
        XCTAssertEqual(card.kind, .goalOffer)
        profile.answer(card, .yes, at: base.addingTimeInterval(day))
        XCTAssertEqual(profile.activeFocus?.id, offer.id)
        profile.takeBack(card.id, at: base.addingTimeInterval(day + 5))
        XCTAssertEqual(profile.activeFocus?.id, old.id, "the focus the yes replaced is active again")
        XCTAssertEqual(profile.focus, old.plan)
        XCTAssertEqual(profile.proposedFocus?.id, offer.id)
        // "Undo" in the list of what was blocked only takes the block away: it does not change a focus.
        var never = profile
        never.answer(card, .never, at: base.addingTimeInterval(2 * day))
        XCTAssertTrue(never.training(asOf: base).isGoalBlocked(dates))
        let foci = never.foci
        never.allowAgain(card.id, at: base.addingTimeInterval(90 * day))
        XCTAssertFalse(never.training(asOf: base).isGoalBlocked(dates))
        XCTAssertEqual(never.foci, foci)
        XCTAssertEqual(never.neverAgain, [])
        // For a conclusion or a subject, allowing it again is the same as taking the answer back.
        var subject = CoachProfile()
        let first = deck(made, subject)[0]
        subject.answer(first, .never, at: base)
        subject.allowAgain(first.id, at: base.addingTimeInterval(day))
        XCTAssertFalse(subject.training(asOf: base).isBlocked(dates))
    }

    func testAConclusionWithNoPersonFieldStillGivesAReview() {
        var reply: Any = ["questions": [["statement": "Sam reports to you.", "kind": "relationship", "evidence": "E", "at_seconds": 40]]]
        let problems = SchemaCheck.fill(&reply, schema: LLMCoach.schema)
        XCTAssertFalse(problems.contains { $0.contains("person") }, "\(problems)")
        let filled = ((reply as? [String: Any])?["questions"] as? [[String: Any]])?.first
        XCTAssertTrue(filled?["person"] is NSNull)
    }

    func testTheDeckIsShortTwoCardsACallTenInAllAndOlderReviewsSeedOnlyTheLastWeek() {
        XCTAssertEqual(FindingRules.deckLimit, 10)
        XCTAssertEqual(FindingRules.seedDays, 7)
        let reviews = (0..<8).map { i in
            (callID: "n\(i)", date: base.addingTimeInterval(Double(i) * day),
             review: settle(review(tryNext: advice, didWell: praise), call("n\(i)", day: Double(i))).review)
        }
        let all = FindingRules.deck(reviews: reviews, profile: CoachProfile(), now: base.addingTimeInterval(8 * day))
        XCTAssertEqual(all.count, 10, "never a backlog")
        XCTAssertEqual(Array(Set(all.map(\.callID))).sorted(), ["n3", "n4", "n5", "n6", "n7"], "the newest calls")
        XCTAssertEqual(all.first?.callID, "n7")
        // A review from before the cards gives its cards only for the last week at the first launch.
        var old = review(tryNext: advice)
        old.version = CoachReview.currentVersion
        old.line = CoachLine(kind: .tryNext, note: advice)
        XCTAssertEqual(deck(old, now: 6.9).count, 1)
        XCTAssertEqual(deck(old, now: 7.1).count, 0)
        // A card of this build waits two weeks, as before.
        XCTAssertEqual(deck(settle(review(tryNext: advice)).review, now: 13.9).count, 1)
    }

    func testALaterNoOrNeverOnAnotherDeviceRemovesTheFactOfAnEarlierYes() {
        var asked = CoachProfile()
        asked.ask([question()])
        let card = deck(review(), asked)[0]
        for later in [FindingVerdict.no, .never] {
            var mac = asked, phone = asked
            mac.answer(card, .yes, at: base.addingTimeInterval(day))
            phone.answer(card, later, at: base.addingTimeInterval(day + 60))
            for merged in [mac.merged(with: phone), phone.merged(with: mac, takeCoaching: true)] {
                XCTAssertEqual(merged.answer(to: card.id)?.verdict, later)
                XCTAssertEqual(merged.facts, [], "\(later)")
                XCTAssertFalse(CoachPrompt.user(record: call("d", day: 2), owner: owner, profile: merged).contains("Relationships:"))
            }
        }
        // A later yes keeps its fact.
        var mac = asked, phone = asked
        phone.answer(card, .no, at: base.addingTimeInterval(day))
        mac.answer(card, .yes, at: base.addingTimeInterval(day + 60))
        XCTAssertEqual(phone.merged(with: mac).facts.map(\.text), ["Sam reports to you."])
        XCTAssertEqual(mac.merged(with: phone).facts.map(\.text), ["Sam reports to you."])
    }

    func testReasonsForANoDoNotPushOutTheOwnersOwnGuidance() {
        var profile = CoachProfile()
        profile.updateGuidance(add: (1...6).map { "Own rule \($0)." }, remove: [], at: base)
        for i in 0..<30 {
            let c = card(callID: "r\(i)")
            profile.answer(c, .no, at: base.addingTimeInterval(Double(i)))
            profile.explain(c.id, note: "Reason \(i).", at: base.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(profile.ownGuidance.count, 6)
        XCTAssertEqual(profile.whyRules.count, CoachProfile.reasonLimit)
        XCTAssertEqual(CoachProfile.reasonLimit, 10)
        XCTAssertTrue(profile.whyRules.first?.text.contains("Reason 29.") == true, "the newest first")
        XCTAssertFalse(profile.guidance.contains { $0.text.contains("Reason 19.") })
        let text = CoachPrompt.user(record: call("d", day: 1), owner: owner, profile: profile)
        let own = text.components(separatedBy: "## What \(owner) told you about your coaching (follow this)\n").last?.components(separatedBy: "\n\n").first ?? ""
        XCTAssertTrue(own.contains("Own rule 1."), own)
        XCTAssertFalse(own.contains("Reason"), "a reason is about one card, not a rule for each review")
        // A reason goes with its subject.
        let training = CoachPrompt.trainingText(profile, record: call("d", day: 1))
        XCTAssertTrue(training.contains("Reason 29."), training)
        XCTAssertTrue(training.contains(dates), training)
    }

    func testANoOnAConclusionKeepsTheModelFromAskingForThirtyDaysOnly() {
        var profile = CoachProfile()
        profile.ask([question()])
        profile.answer(deck(review(), profile)[0], .no, at: base.addingTimeInterval(day))
        XCTAssertTrue(CoachPrompt.questionsText(profile, now: base.addingTimeInterval(20 * day)).contains("Not confirmed"))
        XCTAssertFalse(CoachPrompt.questionsText(profile, now: base.addingTimeInterval(40 * day)).contains("Sam reports to you."))
        XCTAssertFalse(CoachPrompt.user(record: call("d", day: 40), owner: owner, profile: profile).contains("Sam reports to you."))
        XCTAssertTrue(CoachPrompt.user(record: call("d", day: 20), owner: owner, profile: profile).contains("Sam reports to you."))
    }

    func testAYesOnAConclusionAboutOneCallIsNoFactForLaterCalls() {
        var profile = CoachProfile()
        var q = question("This call was a negotiation.")
        q.kind = .thisCall
        profile.ask([q])
        let card = deck(review(), profile)[0]
        profile.answer(card, .yes, at: base)
        XCTAssertEqual(profile.facts, [])
        XCTAssertEqual(profile.questions[0].status, .confirmed)
        XCTAssertFalse(CoachPrompt.user(record: call("d", day: 1), owner: owner, profile: profile).contains("This call was a negotiation."))
        XCTAssertTrue(CoachPrompt.user(record: call("c"), owner: owner, profile: profile).contains("This call was a negotiation."), "a new review of the same call")
        profile.takeBack(card.id, at: base.addingTimeInterval(60))
        XCTAssertEqual(profile.questions[0].status, .open)
        XCTAssertEqual(profile.forgotten, [:], "there was no fact to forget")
    }

    func testNeverAgainIsNotOfferedOnACardOfTheActiveFocus() {
        var profile = CoachProfile()
        let focus = CoachFocus(plan: "When you take an item, say the day.", why: "W", metric: nil, proposed: base, skill: dates)
        profile.propose(focus, at: base)
        profile.acceptFocus(focus.id, plan: nil, at: base)
        XCTAssertFalse(FindingRules.offersNever(card(), profile: profile))
        XCTAssertFalse(FindingRules.offersNever(card(.didWell, skill: "focus:\(focus.id.uuidString)"), profile: profile))
        XCTAssertTrue(FindingRules.offersNever(card(.didWell, skill: risk), profile: profile))
        XCTAssertTrue(FindingRules.offersNever(card(), profile: CoachProfile()))
    }

    func testAReleaseAnswersPastTheThresholdOrOnAQuickFlick() {
        XCTAssertEqual(DeckRelease.verdict(x: 120, predicted: 130), .yes)
        XCTAssertEqual(DeckRelease.verdict(x: -120, predicted: -130), .no)
        XCTAssertNil(DeckRelease.verdict(x: 60, predicted: 80), "the card springs back")
        XCTAssertEqual(DeckRelease.verdict(x: 45, predicted: 300), .yes, "a quick flick")
        XCTAssertEqual(DeckRelease.verdict(x: -45, predicted: -300), .no)
        XCTAssertNil(DeckRelease.verdict(x: 20, predicted: 300), "too short for a flick")
        XCTAssertNil(DeckRelease.verdict(x: 60, predicted: -300), "a flick back the other way")
    }

    func testATwoFingerSwipeIsTakenOnlyOnceItsDirectionIsKnown() {
        typealias E = ScrollSwipe.Event
        var s = ScrollSwipe()
        // A slow start of a scroll down over the deck: the page gets each event, the first one too.
        XCTAssertEqual(s.handle(E(phase: .began, dx: 0, dy: -1)), .pass)
        XCTAssertEqual(s.handle(E(phase: .changed, dx: 0.5, dy: -1)), .pass)
        XCTAssertEqual(s.handle(E(phase: .changed, dx: 0, dy: -4)), .pass)
        XCTAssertEqual(s.handle(E(phase: .changed, dx: 9, dy: 0)), .pass, "the page's scroll stays the page's")
        XCTAssertEqual(s.handle(E(phase: .ended)), .pass)
        XCTAssertEqual(s.handle(E(momentum: .changed, dy: -3)), .pass)
        // A swipe to the side: the card moves once the direction is known.
        XCTAssertEqual(s.handle(E(phase: .began, dx: 2)), .pass)
        XCTAssertEqual(s.handle(E(phase: .changed, dx: 6)), .take(.move(8)))
        XCTAssertEqual(s.handle(E(phase: .changed, dx: 40, dy: 1)), .take(.move(48)))
        // The end: the page sees it too, the speed is the mean of the last moves, and the glide is not the page's.
        XCTAssertEqual(s.handle(E(phase: .ended)), .pass(.release(x: 48, speed: 16)))
        XCTAssertEqual(s.handle(E(momentum: .changed, dx: 5)), .take(nil))
        XCTAssertEqual(s.handle(E(momentum: .ended)), .take(nil))
        XCTAssertEqual(s.handle(E(momentum: .changed, dy: -3)), .pass)
        // A swipe that the system cancels lets the card go back.
        _ = s.handle(E(phase: .began, dx: 3))
        _ = s.handle(E(phase: .changed, dx: 30))
        XCTAssertEqual(s.handle(E(phase: .cancelled)), .pass(.cancel))
        // Not over the part of the deck that shows: the page's.
        XCTAssertEqual(s.handle(E(phase: .began, dx: 3, inside: false)), .pass)
        XCTAssertEqual(s.handle(E(phase: .changed, dx: 30, inside: false)), .pass)
        XCTAssertEqual(s.handle(E(phase: .ended, inside: false)), .pass)
        // A mouse wheel has no phases.
        XCTAssertEqual(s.handle(E(dx: 30)), .pass)
    }

    // MARK: The pages of Coach

    func testTheGoalsPageListsTheGoalOfNowWhatWasOfferedAndWhatWasLearned() {
        var profile = CoachProfile()
        XCTAssertEqual(profile.goalHistory.offered, [])
        let a = CoachFocus(plan: "A", why: "W", metric: nil, proposed: base, skill: dates)
        let b = CoachFocus(plan: "B", why: "W", metric: nil, proposed: base.addingTimeInterval(day), skill: risk)
        let c = CoachFocus(plan: "C", why: "W", metric: nil, proposed: base.addingTimeInterval(2 * day), skill: CoachSkill.longTurns.rawValue)
        profile.propose(a, at: a.proposed)
        profile.acceptFocus(a.id, plan: nil, at: a.proposed)
        for i in 0..<5 { profile.record(FocusResult(callID: "h\(i)", date: base.addingTimeInterval(Double(i) * 3600), outcome: .hit, evidence: "E"), focus: a.id) }
        profile.propose(b, at: b.proposed)
        profile.dismissFocus(b.id, at: b.proposed)
        profile.propose(c, at: c.proposed)
        let goals = profile.goalHistory
        XCTAssertEqual(goals.current?.id, c.id, "a proposal waits for an answer")
        XCTAssertEqual(goals.offered.map(\.id), [b.id])
        XCTAssertEqual(goals.finished.map(\.id), [a.id])
    }

    func testAWeeklyEmailThatIsWrittenAndNotSentYetIsFound() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(WeeklyDigest.waiting(in: dir).count, 0)
        let digest = WeeklyDigest(subject: "Your week", intro: "I", improved: ["a"], toWork: ["b"], focus: "F")
        try JSONEncoder.coach.encode(digest).write(to: dir.appendingPathComponent("email-weekly-\(Int(base.timeIntervalSince1970)).json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("profile.json"))
        let found = WeeklyDigest.waiting(in: dir)
        XCTAssertEqual(found.map(\.digest), [digest])
        XCTAssertEqual(found.first?.start, base)
        XCTAssertEqual(found.first?.weekly, true)
    }
}
