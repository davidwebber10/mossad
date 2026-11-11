import XCTest
@testable import MossadCore

/// One line after a call or nothing: proof for each line, no advice twice, and a memory that adds.
final class CoachLineTests: XCTestCase {
    private let owner = "Dana Lee"
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    // MARK: Helpers

    /// A 30 minute 1:1 on day `day`: Dana's lines and Sam's, in order.
    private func call(_ id: String = "c", day n: Double = 0, _ lines: [(who: String, at: TimeInterval, text: String)] = []) -> CallRecord {
        let lines = lines.isEmpty ? [("me", 10, "I will send the forecast to finance."), ("them", 40, "When can we see the forecast?"),
                                     ("me", 760, "Let me look at it and get back to you."), ("me", 900, "My read is that the vendor price holds until March.")] : lines
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: base.addingTimeInterval(n * day), end: base.addingTimeInterval(n * day + 1800), status: .written)
        r.speakerNames = ["me:A": owner, "them:A": "Sam Carter"]
        r.utterances = lines.map { Utterance(track: $0.0 == "me" ? .me : .them, speakerLabel: "A", start: $0.1, end: $0.1 + 20, text: $0.2) }
        return r
    }

    private func review(tryNext: CoachNote? = nil, didWell: CoachNote? = nil, quiet: Bool = false) -> CoachReview {
        var r = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        r.tryNext = tryNext
        r.didWell = didWell
        r.quiet = quiet
        return r
    }

    private let dates = CoachSkill.commitmentDates.rawValue
    private let risk = "other:name the risk"

    private func advice(_ quote: String = "Let me look at it and get back to you.", at: TimeInterval? = 760, skill: String? = nil,
                        text: String = "When you take an item, say the day.") -> CoachNote {
        CoachNote(text: text, quote: quote, at: at, say: "I will send it by Friday.", skill: skill ?? dates)
    }

    private var praise: CoachNote { CoachNote(text: "You named the risk.", quote: "My read is that the vendor price holds", at: 900, skill: risk) }

    private func said(_ skill: String, daysAgo: Double, callID: String = "old", kind: CoachLine.Kind = .tryNext, held: Bool = false, shown: Bool = true) -> CoachAdvice {
        CoachAdvice(callID: callID, date: base.addingTimeInterval(-daysAgo * day), kind: kind, skill: skill, text: "T", at: 5, held: held, shown: shown)
    }

    private func settle(_ review: CoachReview, _ record: CallRecord? = nil, profile: CoachProfile = CoachProfile(),
                        measured: CoachMeasured = CoachMeasured(), patterns: [CoachPatternUpdate] = []) -> CoachResult {
        CoachLineRules.settle(CoachResult(review: review, update: CoachProfileUpdate(summary: "", focus: "", patterns: patterns, people: [])),
                              record: record ?? call(), owner: owner, profile: profile, measured: measured)
    }

    private func point(_ title: String, quote: String, tryInstead: String? = nil) -> CoachPoint {
        CoachPoint(title: title, observation: "O", quote: quote, at: 1, principle: "P", tryInstead: tryInstead)
    }

    // MARK: Proof

    func testAdviceWithTheOwnersOwnWordsBecomesTheLineAtThatMoment() {
        let out = settle(review(tryNext: advice(at: 700), didWell: praise))
        XCTAssertEqual(out.review.line?.kind, .tryNext)
        XCTAssertEqual(out.review.line?.text, "When you take an item, say the day.")
        XCTAssertEqual(out.review.line?.at, 760, "the time is where code found the words")
        XCTAssertEqual(out.review.line?.say, "I will send it by Friday.")
        XCTAssertEqual(out.review.line?.skill, dates)
        XCTAssertEqual(out.review.version, CoachReview.currentVersion)
        XCTAssertEqual(out.advice.map(\.kind), [.tryNext, .didWell])
        XCTAssertEqual(out.advice.map(\.shown), [true, false], "the owner got the line; the praise waits in the full review")
        XCTAssertEqual(out.review.others.map(\.kind), [.didWell])
    }

    func testAQuoteThatIsNotTheOwnersOwnLineIsNoProof() {
        // Sam said it, and the second quote is in no line at all.
        let out = settle(review(tryNext: advice("When can we see the forecast?", at: 40),
                                didWell: CoachNote(text: "You closed well.", quote: "We agreed on every owner and every date.", at: 900, skill: risk)))
        XCTAssertNil(out.review.line)
        XCTAssertNil(out.review.tryNext, "advice without proof is not kept, not in the full review also")
        XCTAssertNil(out.review.didWell)
        XCTAssertEqual(out.dropped.count, 2)
        XCTAssertTrue(out.advice.isEmpty, "a line without proof was not said")
    }

    func testAQuoteNeedsThreeWordsAndEveryShownWordInOneLine() {
        let r = call()
        XCTAssertNil(CoachLineRules.ownerMoment(quote: "Let me", in: r, owner: owner), "two words are in many lines")
        XCTAssertNil(CoachLineRules.ownerMoment(quote: "", in: r, owner: owner))
        XCTAssertNil(CoachLineRules.ownerMoment(quote: "Let me look at it and get back to them.", in: r, owner: owner), "the last word is not what the owner said")
        XCTAssertNil(CoachLineRules.ownerMoment(quote: "send the forecast to finance. Let me look", in: r, owner: owner), "two lines are not one moment")
        XCTAssertEqual(CoachLineRules.ownerMoment(quote: "let me look at it, and get back to you", in: r, owner: owner)?.at, 760, "case and punctuation are the transcriber's")
    }

    func testTheMomentIsWhereTheWordsAreInALongTurn() {
        // 100 words in 200 s, the quote from word 51; then the same with word times from the transcriber.
        let words = (1...100).map { "w\($0)" }
        var r = call("c", [("me", 100, words.joined(separator: " "))])
        r.utterances[0].end = 300
        XCTAssertEqual(CoachLineRules.ownerMoment(quote: "w51 w52 w53", in: r, owner: owner)?.at ?? 0, 200, accuracy: 0.01)
        r.utterances[0].words = words.enumerated().map { Word(text: $0.element, start: 100 + Double($0.offset) * 3, end: 100 + Double($0.offset) * 3 + 1) }
        XCTAssertEqual(CoachLineRules.ownerMoment(quote: "w51 w52 w53", in: r, owner: owner)?.at, 250)
    }

    func testTheShownQuoteEndsAtTheLastWordThatWasChecked() {
        // "follow-up" and "3.5" are two words each for the check, so 12 checked words are 10 words between spaces.
        let said = "The follow-up on the 3.5 percent price holds until the vendor signs the new contract in March."
        let moment = CoachLineRules.ownerMoment(quote: said, in: call("c", [("me", 5, said)]), owner: owner)
        XCTAssertEqual(moment?.quote, "The follow-up on the 3.5 percent price holds until the…")
        // The words after the cut are not what the owner said: no word that is shown is one of them.
        let other = "The follow-up on the 3.5 percent price holds until the board agrees to everything."
        XCTAssertEqual(CoachLineRules.ownerMoment(quote: other, in: call("c", [("me", 5, said)]), owner: owner)?.quote, moment?.quote)
        XCTAssertEqual(CoachLineRules.ownerMoment(quote: "Let me look at it", in: call(), owner: owner)?.quote, "Let me look at it", "a short quote stays whole")
    }

    func testAQuietReviewHasNoLine() {
        let out = settle(review(quiet: true))
        XCTAssertNil(out.review.line)
        XCTAssertNil(out.review.shownLine)
        XCTAssertTrue(out.review.saysNothing)
        XCTAssertTrue(out.advice.isEmpty)
    }

    func testEveryLineHasProof() {
        XCTAssertFalse(CoachLine(kind: .tryNext, text: "T", skill: "S").hasProof)
        XCTAssertTrue(CoachLine(kind: .tryNext, text: "T", skill: "S", at: 3).hasProof)
        XCTAssertTrue(CoachLine(kind: .number, text: "T", skill: "S", number: "Usually 30 to 40%").hasProof)
    }

    func testALongQuoteIsCutToItsFirstWords() {
        let long = (1...40).map { "word\($0)" }.joined(separator: " ")
        let out = settle(review(tryNext: advice(long, at: 5)), call("c", [("me", 5, long)]))
        XCTAssertEqual(out.review.line?.quote?.split(separator: " ").count, CoachLineRules.quoteWords)
        XCTAssertTrue(out.review.line?.quote?.hasSuffix("…") == true)
    }

    // MARK: Short, and no trend from the model

    func testALineKeepsToThirtyFiveWords() {
        // 16 words of advice, 12 of quote, 8 to say, and 10 of the number: 46.
        let text = "When Sam asks you for the budget answer in the weekly sync, say the day first."
        let quote = "I can take the budget answer and the plan for the two hires"
        var note = advice(quote, at: 5, text: text)
        note.say = "I will have the budget answer by Thursday."
        let out = settle(review(tryNext: note), call("c", [("me", 5, quote + " next.")]), measured: CoachMeasured(commitments: CommitmentShare(withDay: 4, total: 33)))
        let line = try! XCTUnwrap(out.review.line)
        XCTAssertLessThanOrEqual(line.words, CoachLineRules.lineWords)
        XCTAssertNil(line.quote, "the quote's text goes first")
        XCTAssertEqual(line.at, 5, "its time stays, and plays the moment")
        XCTAssertNotNil(line.say)
        XCTAssertNotNil(line.number)
        // Without the time there is nothing to drop the quote for, and then the words to say go.
        let long = CoachLine(kind: .number, text: text, skill: "S", say: note.say, number: text + " " + text)
        XCTAssertNil(CoachLineRules.fit(long).say)
        XCTAssertEqual(CoachLineRules.fit(CoachLine(kind: .tryNext, note: advice())).quote, advice().quote, "a short line stays whole")
    }

    func testANoteThatIsTooLongOrJudgesATrendIsDropped() {
        let long = advice(text: (1...25).map { "word\($0)" }.joined(separator: " "))
        let trend = CoachNote(text: "You again took an item with no day, the third time this week.", quote: "My read is that the vendor price holds", at: 900, skill: risk)
        let out = settle(review(tryNext: long, didWell: trend))
        XCTAssertNil(out.review.line)
        XCTAssertEqual(out.dropped.count, 2, out.dropped.joined(separator: "; "))
        for claim in ["Longest turn 91 s, down from 152 s.", "You asked more questions than last week.", "This is better than before.", "Your pace improved."] {
            XCTAssertTrue(CoachLineRules.judgesTrend(claim), claim)
        }
        for plain in ["When Sam asks again, give the day.", "Say the better option first.", "Ask for more time."] {
            XCTAssertFalse(CoachLineRules.judgesTrend(plain), plain)
        }
    }

    func testFillerWordsAreNotCoachedAndPaceOnlyAsTheFocus() {
        XCTAssertNil(settle(review(tryNext: advice(skill: CoachSkill.fillerWords.rawValue))).review.line)
        XCTAssertNil(settle(review(tryNext: advice(skill: CoachSkill.pace.rawValue))).review.line)
        var profile = CoachProfile()
        profile.propose(CoachFocus(plan: "When you explain a number, slow down.", why: "W", metric: .pace, proposed: base, skill: CoachSkill.longTurns.rawValue), at: base)
        profile.acceptFocus(profile.proposedFocus!.id, plan: nil, at: base)
        XCTAssertEqual(settle(review(tryNext: advice(skill: CoachSkill.pace.rawValue)), profile: profile).review.line?.kind, .tryNext)
    }

    // MARK: No repeats

    func testTheSameAdviceDoesNotComeBackInThirtyDays() {
        var profile = CoachProfile()
        profile.advice = [said(dates, daysAgo: 12)]
        var r = review(tryNext: advice(), didWell: praise)
        r.improvements = [point("The forecast has no day", quote: "Let me look at it and get back to you.", tryInstead: "I will send it by Friday.")]
        r.strengths = [point("Named the risk", quote: "My read is that the vendor price holds")]
        let out = settle(r, profile: profile)
        XCTAssertEqual(out.review.line?.kind, .didWell, "the next thing with proof takes the line")
        XCTAssertNil(out.review.tryNext, "the advice is not written again, not in the full review also")
        XCTAssertTrue(out.review.improvements.isEmpty, "and not as the detail point behind it")
        XCTAssertEqual(out.review.strengths.map(\.title), ["Named the risk"])
        XCTAssertEqual(out.review.seenAgain?.at, 760, "the moment stays, as evidence")
        XCTAssertEqual(out.review.seenAgain?.text, "Give a day with each commitment")
        XCTAssertEqual(out.advice.filter(\.held).map(\.skill), [dates], "the log counts it")
    }

    func testAdviceComesBackAfterThirtyDays() {
        var profile = CoachProfile()
        profile.advice = [said(dates, daysAgo: 31)]
        XCTAssertEqual(settle(review(tryNext: advice()), profile: profile).review.line?.kind, .tryNext)
    }

    func testTheSameSkillIsTheSameAdviceWhateverTheWords() {
        func repeats(_ skill: String, _ entry: CoachAdvice, kind: CoachLine.Kind = .tryNext) -> Bool {
            AdviceRules.earlier(kind: kind, skill: skill, in: [entry], callID: "c", date: base) != nil
        }
        XCTAssertTrue(repeats(dates, said(dates, daysAgo: 3)))
        XCTAssertFalse(repeats(CoachSkill.answerFirst.rawValue, said(dates, daysAgo: 3)), "another skill is other advice, also in the same words")
        XCTAssertTrue(repeats(risk, said("other:name the risk", daysAgo: 3)))
        XCTAssertFalse(repeats(risk, said("other:offer the simple method", daysAgo: 3)))
        XCTAssertFalse(repeats(dates, said(dates, daysAgo: 3, callID: "c")), "a call reviewed again does not repeat itself")
        XCTAssertFalse(repeats(dates, said(dates, daysAgo: 3, held: true)), "a call that was only counted said nothing")
        XCTAssertFalse(repeats(dates, said(dates, daysAgo: 3, shown: false)), "a note in a full review was not the line")
        XCTAssertTrue(repeats(dates, said(dates, daysAgo: 3, kind: .again)), "a count is a line about the skill")
        XCTAssertFalse(repeats(dates, said(dates, daysAgo: 3), kind: .didWell), "praise for the skill is not the advice about it")
    }

    func testAKeyFromTheModelBecomesOneIdForTheLog() {
        XCTAssertEqual(CoachSkill.id(key: "commitment-dates", label: "ignored"), dates)
        XCTAssertEqual(CoachSkill.id(key: " Answer-First ", label: nil), "answer-first")
        XCTAssertEqual(CoachSkill.id(key: "other", label: "Name the risk!"), risk)
        XCTAssertEqual(CoachSkill.id(key: "other", label: "name  the RISK"), risk, "a label is the same without case, spaces, and punctuation")
        XCTAssertEqual(CoachSkill.title(of: dates), "Give a day with each commitment")
        XCTAssertEqual(CoachSkill.title(of: risk), "Name the risk")
        XCTAssertEqual(CoachSkill(id: risk), .other)
        XCTAssertNil(CoachSkill(id: "number:talkShare"))
        XCTAssertEqual(CoachSkill.commitmentDates.measure, .commitmentDay)
        XCTAssertEqual(Set(CoachSkill.allCases.map(\.rawValue)).count, CoachSkill.allCases.count)
    }

    func testAnUnknownOrMissingKeyIsOtherAndNeverAnError() {
        XCTAssertEqual(CoachSkill.id(key: " Delegation ", label: ""), "other:delegation", "a key that is not in the list is the label of an other")
        XCTAssertEqual(CoachSkill.id(key: "delegation", label: "Hand work over"), "other:hand work over", "a label that the model gave stays")
        XCTAssertEqual(CoachSkill.id(key: nil, label: "Name the risk"), risk, "no key, with a label")
        XCTAssertEqual(CoachSkill.id(key: nil, label: nil), "other:")
        XCTAssertEqual(CoachSkill.id(key: "other", label: "  "), "other:")
        XCTAssertTrue(CoachSkill.isNamed(dates))
        XCTAssertTrue(CoachSkill.isNamed(risk))
        XCTAssertFalse(CoachSkill.isNamed("other:"), "an other with no label cannot be found again")
        XCTAssertFalse(CoachSkill.isNamed(""))
    }

    func testTheWordRulesNeverRunOnALabelOfTheModel() {
        // Each of these labels has a word that a seed rule knows. A wrong key would hold new advice as a repeat,
        // put the share of commitments next to it, or drop it as "not coached".
        for label in ["Date your items", "Keep the team up to date", "Due diligence on vendors", "Pace the agenda", "Answer the question asked"] {
            XCTAssertEqual(CoachSkill.id(key: "other", label: label), "other:" + label.lowercased(), label)
        }
        var profile = CoachProfile()
        profile.advice = [said(CoachSkill.questions.rawValue, daysAgo: 3)]
        let out = settle(review(tryNext: advice(skill: CoachSkill.id(key: "other", label: "Answer the question asked"))), profile: profile,
                         measured: CoachMeasured(commitments: CommitmentShare(withDay: 4, total: 33)))
        XCTAssertEqual(out.review.line?.kind, .tryNext, "it is not the advice about questions")
        XCTAssertNil(out.review.line?.number)
        // For the seed, a line about an answer is not a line about questions.
        XCTAssertNil(CoachSkill.infer("Answer the question that Sam asked before you add the context."))
    }

    func testANoteWithNoSkillNameIsDroppedAndTheReviewGoesOn() {
        let out = settle(review(tryNext: advice(skill: "other:"), didWell: praise))
        XCTAssertNil(out.review.tryNext, "the log could not find it again, so it could come after each call")
        XCTAssertEqual(out.review.line?.kind, .didWell)
        XCTAssertEqual(out.dropped.count, 1)
        var none = advice()
        none.skill = nil
        XCTAssertNil(settle(review(tryNext: none)).review.line)
    }

    func testPraiseForTheAdvisedSkillIsNotARepeatButTheSamePraiseIs() {
        var profile = CoachProfile()
        profile.advice = [said(dates, daysAgo: 5)]
        let did = CoachNote(text: "You gave a day: Friday for the forecast.", quote: "I will send the forecast to finance.", at: 10, skill: dates)
        XCTAssertEqual(settle(review(didWell: did), profile: profile).review.line?.kind, .didWell, "the owner did what was advised: that is news")
        profile.advice.append(said(dates, daysAgo: 2, callID: "older", kind: .didWell))
        let again = settle(review(didWell: did), profile: profile)
        XCTAssertNil(again.review.line)
        XCTAssertNil(again.review.didWell)
    }

    func testTheAcceptedFocusIsTheLineOnEachCallThatGaveAChanceWithTheOwnersWords() {
        var profile = CoachProfile()
        profile.propose(CoachFocus(plan: "When you take an item, say the day.", why: "W", metric: nil, proposed: base, skill: dates), at: base)
        let id = profile.proposedFocus!.id
        profile.acceptFocus(id, plan: nil, at: base)
        profile.record(FocusResult(callID: "a", date: base.addingTimeInterval(-2 * day), outcome: .hit, evidence: "E"), focus: id)
        profile.record(FocusResult(callID: "b", date: base.addingTimeInterval(-day), outcome: .missed, evidence: "E"), focus: id)
        profile.advice = [said(dates, daysAgo: 1, callID: "b", kind: .focus)]
        var r = review(tryNext: advice(skill: CoachSkill.questions.rawValue))
        r.focusID = id
        r.focusResult = FocusResult(callID: "c", date: base, outcome: .hit, evidence: "You gave Friday for the forecast.", at: 400, quote: "I will send the forecast to finance.")
        let out = settle(r, profile: profile, measured: CoachMeasured(commitments: CommitmentShare(withDay: 4, total: 33)))
        XCTAssertEqual(out.review.line?.kind, .focus, "the owner's goal comes first, and it may come each call")
        XCTAssertEqual(out.review.line?.outcome, .hit)
        XCTAssertEqual(out.review.line?.at, 10, "where the owner said it")
        XCTAssertEqual(out.review.focusResult?.at, 10)
        XCTAssertEqual(out.review.line?.number, "2 of 3 chances. 4 of 33 commitments with a day (12%), last 30 days")
        XCTAssertEqual(out.review.others.map(\.kind), [.tryNext])

        // Advice about the focus's own skill would say the result twice.
        r.tryNext = advice()
        let same = settle(r, profile: profile)
        XCTAssertNil(same.review.tryNext)
        XCTAssertNil(same.review.seenAgain)

        // A verdict with no words of the owner counts for the focus and is not a line.
        r.tryNext = advice(skill: CoachSkill.questions.rawValue)
        r.focusResult = FocusResult(callID: "c", date: base, outcome: .hit, evidence: "You gave Friday for the forecast.", at: 10)
        let claim = settle(r, profile: profile)
        XCTAssertEqual(claim.review.line?.kind, .tryNext)
        XCTAssertEqual(claim.review.focusResult?.outcome, .hit)

        r.focusResult = FocusResult(callID: "c", date: base, outcome: .noChance, evidence: "No items came up.")
        XCTAssertEqual(settle(r, profile: profile).review.line?.kind, .tryNext, "no chance is no news")
    }

    func testAFocusThatWaitsForAnAnswerIsAdviceThatWasSaid() {
        var profile = CoachProfile()
        // A proposal from before the skill list: its words give the key.
        profile.propose(CoachFocus(plan: "When you take or hand over an item, name the day.", why: "W", metric: nil, proposed: base.addingTimeInterval(-18 * day)), at: base)
        XCTAssertEqual(profile.proposedFocus?.skillID, dates)
        XCTAssertEqual(profile.proposedFocus?.measure, .commitmentDay)
        let out = settle(review(tryNext: advice()), profile: profile)
        XCTAssertNil(out.review.line, "the proposal is that advice already")
        XCTAssertEqual(out.advice.map(\.held), [true])
    }

    func testAdviceThatMoreCallsShowComesBackAsACountNotAsAdvice() {
        var profile = CoachProfile()
        profile.advice = [said(dates, daysAgo: 9, callID: "first")]
        var r = review()
        r.seenAgain = CoachNote(text: "", quote: "Let me look at it and get back to you.", at: 760, skill: dates)
        // One more call: counted, not said.
        let one = settle(r, profile: profile)
        XCTAssertNil(one.review.line)
        XCTAssertEqual(one.advice.map(\.held), [true])
        // The third call in more than a week, of five that the coach reviewed: the count, with the moment and the number.
        profile.advice += [said(dates, daysAgo: 6, callID: "x", held: true), said(dates, daysAgo: 2, callID: "y", held: true)]
        profile.history = ["x", "q1", "y", "q2"].enumerated().map {
            CoachHistoryEntry(callID: $0.element, title: "T", date: base.addingTimeInterval(Double($0.offset - 7) * day), headline: "H")
        }
        let commitments = CommitmentShare(withDay: 4, total: 33)
        let three = settle(r, profile: profile, measured: CoachMeasured(commitments: commitments))
        XCTAssertEqual(three.review.line?.kind, .again)
        XCTAssertEqual(three.review.line?.at, 760)
        XCTAssertEqual(three.review.line?.skill, dates)
        XCTAssertNil(three.review.line?.say, "the count does not give the advice again")
        XCTAssertTrue(three.review.line?.text.hasPrefix("Give a day with each commitment: 3 of your 5 calls since") == true, three.review.line?.text ?? "")
        XCTAssertEqual(three.review.line?.number, commitments.text)
        XCTAssertEqual(three.advice.map(\.held), [false], "a count that was shown starts the count again")
        // Good news from the call comes before a count.
        var both = r
        both.didWell = praise
        XCTAssertEqual(settle(both, profile: profile).review.line?.kind, .didWell)
        // Three calls in three days are not a week.
        profile.advice = [said(dates, daysAgo: 3, callID: "first"), said(dates, daysAgo: 2, callID: "x", held: true), said(dates, daysAgo: 1, callID: "y", held: true)]
        XCTAssertNil(settle(r, profile: profile).review.line)
    }

    func testTheCountComesTwoTimesWithMoreDaysBetweenAndThenStops() {
        func held(_ ids: [String], from: Double) -> [CoachAdvice] { ids.enumerated().map { said(dates, daysAgo: from - Double($0.offset) - 1, callID: $0.element, held: true) } }
        func due(_ log: [CoachAdvice], after: CoachAdvice) -> Bool { AdviceRules.again(after: after, in: log, reviewed: [], callID: "c", date: base).due }
        // The advice 25 days ago, the first count 14 days ago, and two more calls since.
        let advised = said(dates, daysAgo: 25, callID: "first"), count = said(dates, daysAgo: 14, callID: "count", kind: .again)
        let log = [advised, count] + held(["x", "y"], from: 10)
        XCTAssertTrue(due(log, after: count), "the second count waits 14 days")
        let sooner = said(dates, daysAgo: 10, callID: "count", kind: .again)
        XCTAssertFalse(due([advised, sooner] + held(["x", "y"], from: 9), after: sooner))
        // After two counts the coach is silent, until 30 days pass and the advice itself can come again.
        let second = said(dates, daysAgo: 20, callID: "count2", kind: .again)
        XCTAssertFalse(due([said(dates, daysAgo: 29, callID: "first"), said(dates, daysAgo: 28, callID: "count", kind: .again), second] + held(["x", "y", "z"], from: 10), after: second))
    }

    func testSeenAgainNeedsEarlierAdviceAndTheOwnersWords() {
        var r = review()
        r.seenAgain = CoachNote(text: "", quote: "Let me look at it and get back to you.", at: 760, skill: dates)
        let none = settle(r)
        XCTAssertNil(none.review.seenAgain, "nothing was said before")
        XCTAssertTrue(none.advice.isEmpty)
        var profile = CoachProfile()
        profile.advice = [said(dates, daysAgo: 9)]
        r.seenAgain?.quote = "When can we see the forecast?"
        XCTAssertTrue(settle(r, profile: profile).advice.isEmpty, "Sam's words are not the owner's moment")
    }

    // MARK: The full review

    func testADetailPointGoesWithItsNoteAndNeedsTheSameProof() {
        var r = review(tryNext: advice("When can we see the forecast?", at: 40), didWell: praise)
        r.improvements = [point("The forecast has no day", quote: "When can we see the forecast?", tryInstead: "By Friday.")]
        r.strengths = [point("Named the risk", quote: "My read is that the vendor price holds"), point("Listened", quote: "When can we see the forecast?")]
        let out = settle(r)
        XCTAssertTrue(out.review.improvements.isEmpty, "the advice had no proof, so its point goes too")
        XCTAssertEqual(out.review.strengths.map(\.title), ["Named the risk"], "a point with another person's words is not kept")
        XCTAssertEqual(out.review.strengths.first?.at, 900)
    }

    func testANoteThatDidNotGetTheLineWaitsInOneFullReviewAndCanStillBeTheLine() {
        // A trend took the line: the advice waits in the full review and was not "said".
        let trend = CoachTrend(id: "oneOnOneShare", text: "You leave more room in your 1:1s with Sam.", proof: "P")
        let first = settle(review(tryNext: advice()), measured: CoachMeasured(trend: trend))
        XCTAssertEqual(first.review.line?.kind, .progress)
        XCTAssertNotNil(first.review.tryNext)
        XCTAssertEqual(first.advice.map(\.shown), [true, false])
        var profile = CoachProfile()
        profile.advice = first.advice.map { var a = $0; a.callID = "old"; a.date = base.addingTimeInterval(-2 * day); return a }
        // The next call: the trend is not news twice, so the advice is the line, for the first time.
        XCTAssertEqual(settle(review(tryNext: advice()), profile: profile, measured: CoachMeasured(trend: trend)).review.line?.kind, .tryNext)
        // A call where it loses the line again does not write it into a second full review.
        let number = CoachMeasured.Standout(id: "longestTurn", text: "held one turn for 4 min; usually up to 2 min in your 1:1s with Sam", at: 30)
        var focused = profile
        focused.advice.append(said(risk, daysAgo: 1, callID: "p", kind: .didWell, shown: false))
        let again = settle(review(didWell: praise), profile: focused, measured: CoachMeasured(standouts: [number]))
        XCTAssertEqual(again.review.line?.kind, .number)
        XCTAssertNil(again.review.didWell)
        XCTAssertEqual(again.advice.map(\.kind), [.number])
    }

    // MARK: Measured lines

    func testANumberThatIsNotUsualIsTheLineWhenTheModelHasNone() {
        let measured = CoachMeasured(standouts: [CoachMeasured.Standout(id: "talkShare", text: "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam", at: nil)])
        let out = settle(review(quiet: true), measured: measured)
        XCTAssertEqual(out.review.line?.kind, .number)
        XCTAssertEqual(out.review.line?.text, "You talked 81% of the time.")
        XCTAssertEqual(out.review.line?.number, "Usually 62 to 70% in your 1:1s with Sam")
        XCTAssertEqual(out.advice.map(\.skill), ["number:talkShare"])
        var profile = CoachProfile()
        profile.advice = out.advice.map { var a = $0; a.callID = "old"; a.date = base.addingTimeInterval(-4 * day); return a }
        XCTAssertNil(settle(review(quiet: true), profile: profile, measured: measured).review.line, "the same number is not news twice in 30 days")
    }

    func testTheMeasuredNumbersAreTheOwnersFromTheAnalyticsBaselinesWithoutFillersAndQuestions() {
        func facts(_ i: Int, share: Double) -> MeetingFacts {
            MeetingFacts(id: "h\(i)", stamp: 0, start: base.addingTimeInterval(Double(-i - 1) * 7 * day), title: "Dana / Sam", series: "dana sam", kind: nil, tags: [],
                         voices: 2, people: [MeetingFacts.Person(name: owner, isOwner: true, values: [.talkShare: share, .fillersPerMinute: 0.5, .questionsPerHour: 2]),
                                             MeetingFacts.Person(name: "Sam Carter", isOwner: false, values: [.talkShare: 1 - share, .fillersPerMinute: 0.5])], values: [:])
        }
        let history = [0.36, 0.34, 0.35, 0.37, 0.33, 0.35].enumerated().map { facts($0.offset, share: $0.element) }
        // Dana talks 80 of 100 seconds in lines that end with "right?", and says "um" in each second word.
        var r = call("now", (0..<8).map { ("me", Double($0) * 10, Array(repeating: "um plan", count: 5).joined(separator: " ") + ", right?") } + [("them", 80, "Fine.")])
        for i in 0..<8 { r.utterances[i].end = r.utterances[i].start + 10 }
        r.utterances[8].end = 100
        r.calendarTitle = "Dana / Sam"
        let measured = CoachMeasured(record: r, owner: owner, history: history, commitments: [])
        XCTAssertEqual(measured.standouts.map(\.id), ["talkShare"], "her share: not Sam's, not the filler words, and not the lines with a question mark")
        XCTAssertEqual(measured.standouts.first?.text, "talked 80% of the time; usually 33 to 37% in your 1:1s with Sam")
        XCTAssertNil(measured.commitments)
        XCTAssertGreaterThan(measured.longestTurn ?? 0, 0)
        XCTAssertEqual(CoachLineRules.number(measured.standouts[0])?.text, "You talked 80% of the time.")
    }

    func testAdviceComesBeforeANumberAndATrendBeforeAdvice() {
        let number = CoachMeasured.Standout(id: "talkShare", text: "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam", at: nil)
        XCTAssertEqual(settle(review(tryNext: advice()), measured: CoachMeasured(standouts: [number])).review.line?.kind, .tryNext)
        let trend = CoachTrend(id: "oneOnOneShare", text: "You leave more room in your 1:1s with Sam.", proof: "You talked 55% in your last 5 with Sam; 62 to 70% in the 8 before.")
        let out = settle(review(tryNext: advice()), measured: CoachMeasured(standouts: [number], trend: trend))
        XCTAssertEqual(out.review.line?.kind, .progress)
        XCTAssertEqual(out.review.line?.number, trend.proof)
        XCTAssertEqual(out.review.others.map(\.kind), [.tryNext])
    }

    func testTheShareOfCommitmentsWithADayStandsNextToAdviceAboutIt() {
        let share = CommitmentShare(withDay: 4, total: 33)
        let out = settle(review(tryNext: advice()), measured: CoachMeasured(commitments: share))
        XCTAssertEqual(out.review.line?.number, "4 of 33 commitments with a day (12%), last 30 days")
        XCTAssertEqual(out.advice.first?.measure, .commitmentDay)
        XCTAssertNil(settle(review(tryNext: advice(skill: CoachSkill.answerFirst.rawValue)), measured: CoachMeasured(commitments: share)).review.line?.number,
                     "only where the coach speaks of it")
    }

    func testTheShareCountsCommitmentsFromCallsInTheLastThirtyDays() {
        func made(_ daysAgo: Double, due: Bool, call: String? = "x", deleted: Bool = false) -> Commitment {
            var c = Commitment(text: "T", to: nil, callID: call, callTitle: nil, madeAt: base.addingTimeInterval(-daysAgo * day), due: due ? base : nil)
            c.deleted = deleted
            return c
        }
        let items = [made(1, due: true), made(2, due: false), made(3, due: false), made(4, due: false), made(5, due: true), made(6, due: false),
                     made(40, due: true), made(2, due: true, call: nil), made(2, due: true, deleted: true)]
        let share = CommitmentShare(items, asOf: base)
        XCTAssertEqual(share?.withDay, 2)
        XCTAssertEqual(share?.total, 6, "not the old one, the one added by hand, or the deleted one")
        XCTAssertNil(CommitmentShare(Array(items.prefix(4)), asOf: base), "too few to tell")
    }

    // MARK: Trends from code

    func testATrendNeedsEnoughCallsAndAChangeLargerThanTheUsualSpread() {
        let before = [0.66, 0.68, 0.64, 0.70, 0.67, 0.65, 0.69, 0.66]
        XCTAssertNotNil(CoachTrend.shift(before + [0.55, 0.54, 0.57, 0.52, 0.56], margin: 0.08))
        XCTAssertEqual(CoachTrend.shift(before + [0.55, 0.54, 0.57, 0.52, 0.56], margin: 0.08)?.recent ?? 0, 0.55, accuracy: 0.001)
        XCTAssertNil(CoachTrend.shift(before + [0.66, 0.50, 0.67, 0.64, 0.69], margin: 0.08), "one low call is not a trend")
        XCTAssertNil(CoachTrend.shift(before + [0.63, 0.62, 0.64, 0.63, 0.62], margin: 0.08), "a small change is not a trend")
        XCTAssertNil(CoachTrend.shift(Array(before.prefix(4)) + [0.55, 0.54, 0.57, 0.52, 0.56], margin: 0.08), "four earlier calls do not say what is usual")
        XCTAssertNil(CoachTrend.shift(before + [0.55, 0.54], margin: 0.08), "two calls are not a trend")
    }

    func testMoreRoomIsATrendOnlyInOneOnOnesWithTheSamePerson() {
        func facts(_ id: String, daysAgo: Double, share: Double, with other: String = "Sam Carter", third: Bool = false) -> MeetingFacts {
            var people = [MeetingFacts.Person(name: owner, isOwner: true, values: [.talkShare: share]),
                          MeetingFacts.Person(name: other, isOwner: false, values: [.talkShare: 1 - share])]
            if third { people.append(MeetingFacts.Person(name: "Jo Park", isOwner: false, values: [.talkShare: 0.1])) }
            return MeetingFacts(id: id, stamp: 0, start: base.addingTimeInterval(-daysAgo * day), title: id, series: nil, kind: nil, tags: [],
                                voices: people.count, people: people, values: [:])
        }
        let shares = [0.66, 0.68, 0.64, 0.70, 0.67, 0.65, 0.69, 0.66, 0.55, 0.54, 0.57, 0.52]
        let history = shares.enumerated().map { i, s in facts("h\(i)", daysAgo: Double(shares.count - i) * 3, share: s) }
        let trend = CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.56), history: history)
        XCTAssertEqual(trend?.id, "oneOnOneShare")
        XCTAssertEqual(trend?.text, "You leave more room in your 1:1s with Sam.")
        XCTAssertEqual(trend?.proof, "You talked 55% in your last 5 with Sam; 64 to 70% in the 8 before.")
        XCTAssertNil(CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.2, third: true), history: history), "a group is not a 1:1")
        let up = shares.map { 1.2 - $0 }.enumerated().map { i, s in facts("h\(i)", daysAgo: Double(shares.count - i) * 3, share: s) }
        XCTAssertNil(CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.66), history: up), "more talk is not more room")
        // The earlier 1:1s were with direct reports and the last ones with the manager: other people, not other behavior.
        let mixed = shares.enumerated().map { i, s in facts("h\(i)", daysAgo: Double(shares.count - i) * 3, share: s, with: i < 8 ? "Sam Carter" : "Morgan Diaz") }
        XCTAssertNil(CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.56, with: "Morgan Diaz"), history: mixed))
    }

    // MARK: A memory that adds

    func testACallAddsAnObservationAndDoesNotReplaceTheSummaryOrThePatternsNote() {
        var profile = CoachProfile()
        profile.summary = "Direct, and fast to decide."
        profile.patterns = [CoachPattern(name: "Leaves items without a day", kind: .growth, note: "Takes work with no date.", seen: 25,
                                         firstSeen: base.addingTimeInterval(-20 * day), lastSeen: base.addingTimeInterval(-3 * day), trend: .steady)]
        let update = CoachProfileUpdate(summary: "About the last 1:1 only.", focus: "",
                                        patterns: [CoachPatternUpdate(name: "leaves items without a day", kind: .growth, note: "Took the forecast with no day.",
                                                                      result: .missed, quote: "Let me look at it", at: 760)], people: [])
        profile.apply(update, review: review(), callID: "c1", title: "T", at: base)
        XCTAssertEqual(profile.summary, "Direct, and fast to decide.")
        XCTAssertEqual(profile.patterns[0].note, "Takes work with no date.")
        XCTAssertEqual(profile.patterns[0].lastSeen, base)
        XCTAssertEqual(profile.observations.map(\.note), ["Took the forecast with no day."])
        XCTAssertEqual(profile.observations.first?.at, 760)

        let did = CoachProfileUpdate(summary: "", focus: "", patterns: [CoachPatternUpdate(name: "Leaves items without a day", kind: .growth,
                                                                                           note: "Gave Friday for the forecast.", result: .did)], people: [])
        profile.apply(did, review: review(), callID: "c2", title: "T", at: base.addingTimeInterval(day))
        XCTAssertEqual(profile.observations.count, 2, "the first moment is still there")
        let count = profile.count(profile.patterns[0])
        XCTAssertEqual(count.calls, 2)
        XCTAssertEqual(count.showed, 1, "a call that showed the good behavior does not count as the habit")
        XCTAssertEqual(profile.patterns[0].lastSeen, base, "the habit was last seen in the first call")

        // The same call reviewed again replaces its own entries only.
        profile.apply(update, review: review(), callID: "c2", title: "T", at: base.addingTimeInterval(day))
        XCTAssertEqual(profile.observations.map(\.callID), ["c1", "c2"])
        XCTAssertEqual(profile.count(profile.patterns[0]).showed, 2)
    }

    func testAFirstSummaryIsKeptWhenThereIsNone() {
        var profile = CoachProfile()
        profile.apply(CoachProfileUpdate(summary: "A direct communicator.", focus: "", patterns: [], people: []), review: review(), callID: "c", title: "T", at: base)
        XCTAssertEqual(profile.summary, "A direct communicator.")
    }

    func testAPatternSaysWhatTheLogCounted() {
        var profile = CoachProfile()
        let pattern = CoachPattern(name: "Leaves items without a day", kind: .growth, note: "N", seen: 25, firstSeen: base.addingTimeInterval(-60 * day),
                                   lastSeen: base.addingTimeInterval(-45 * day), trend: .improving)
        profile.patterns = [pattern]
        XCTAssertFalse(profile.standing(pattern, now: base).contains("25"), "the old count had no meaning")
        XCTAssertFalse(profile.standing(pattern, now: base).lowercased().contains("improving"), "the model's trend is not shown")
        XCTAssertTrue(profile.standing(pattern, now: base).hasPrefix("Not seen since"), profile.standing(pattern, now: base))
        profile.observations = [CoachObservation(callID: "a", date: base.addingTimeInterval(-2 * day), pattern: pattern.name, result: .missed, note: "N"),
                                CoachObservation(callID: "b", date: base.addingTimeInterval(-day), pattern: pattern.name, result: .did, note: "N")]
        profile.patterns[0].lastSeen = base.addingTimeInterval(-2 * day)
        XCTAssertTrue(profile.standing(profile.patterns[0], now: base).hasPrefix("In 1 of 2 calls"), profile.standing(profile.patterns[0], now: base))
        XCTAssertEqual(profile.standings(now: base), [pattern.name: profile.standing(profile.patterns[0], now: base)], "the list's one pass says the same")
    }

    func testThePatternsHaveALimitAndTheOnesSeenLongestAgoGo() {
        var profile = CoachProfile()
        let updates = (0..<(CoachProfile.patternLimit + 3)).map { CoachPatternUpdate(name: "P\($0)", kind: .growth, note: "N", result: .missed) }
        for (i, u) in updates.enumerated() {
            profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [u], people: []), review: review(), callID: "c\(i)", title: "T", at: base.addingTimeInterval(Double(i) * day))
        }
        XCTAssertEqual(profile.patterns.count, CoachProfile.patternLimit)
        XCTAssertEqual(profile.patterns.first?.name, "P3")
    }

    func testApplyingAReviewLogsItsAdviceOncePerCall() {
        var profile = CoachProfile()
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "c", title: "T", at: base,
                      advice: [said(dates, daysAgo: 0, callID: "c")])
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "c", title: "T", at: base,
                      advice: [said(risk, daysAgo: 0, callID: "c", kind: .didWell)])
        XCTAssertEqual(profile.advice.map(\.skill), [risk])
    }

    func testADeletedMeetingLeavesItsLinesMomentsResultsAndOpenQuestionsNowhere() {
        var profile = CoachProfile()
        profile.propose(CoachFocus(plan: "P", why: "W", metric: nil, proposed: base, skill: dates), at: base)
        let id = profile.proposedFocus!.id
        profile.acceptFocus(id, plan: nil, at: base)
        profile.record(FocusResult(callID: "gone", date: base, outcome: .hit, evidence: "E", quote: "My words"), focus: id)
        profile.record(FocusResult(callID: "stays", date: base, outcome: .missed, evidence: "E"), focus: id)
        profile.advice = [said(dates, daysAgo: 1, callID: "gone"), said(risk, daysAgo: 1, callID: "stays")]
        profile.observations = [CoachObservation(callID: "gone", date: base, pattern: "P", result: .missed, note: "N", quote: "My words", at: 3)]
        var answered = CoachQuestion(statement: "Sam reports to you.", kind: .relationship, evidence: "E", callID: "gone", at: 1, asked: base)
        answered.status = .confirmed
        profile.questions = [CoachQuestion(statement: "The sync is for decisions.", kind: .meetingPurpose, evidence: "E", callID: "gone", at: 1, asked: base), answered]
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "gone", title: "T", at: base)
        profile.forget(callID: "gone")
        XCTAssertEqual(profile.advice.map(\.callID), ["stays"])
        XCTAssertTrue(profile.observations.isEmpty)
        XCTAssertTrue(profile.history.isEmpty)
        XCTAssertEqual(profile.activeFocus?.results.map(\.callID), ["stays"])
        XCTAssertEqual(profile.questions.map(\.statement), ["Sam reports to you."], "what the owner confirmed is a fact of its own")
    }

    // MARK: The log from the older reviews

    /// Made-up advice in the many ways a coach says "give a day": none is copied from a real review.
    private let dayAdvice = [
        "When you take an item, say the day you will send it.",
        "When someone asks what is next, list your own items first, each with a day.",
        "When you hand work to Sam, give a date in the same sentence.",
        "Before you say \u{201C}I'll look into it\u{201D}, add by when.",
        "When you accept a task, name the deadline out loud.",
        "Next time you promise the forecast, say \u{201C}by Thursday\u{201D}.",
        "When a topic closes with an action for you, put a due date on it.",
        "When you claim the follow-up, tell them the day they get it.",
        "If you commit to a deliverable, attach a date before the call moves on.",
        "When Jo asks for the numbers, answer with the day, not with \u{201C}soon\u{201D}.",
        "When you pick up an action item, state which day it lands.",
        "End each item you own with a day: \u{201C}mine, by Tuesday\u{201D}.",
        "When the room asks who has it, say your part and then the day.",
    ]

    func testTheManyWordingsOfGiveADayAreOneSkill() {
        for text in dayAdvice { XCTAssertEqual(CoachSkill.infer(text), .commitmentDates, text) }
        XCTAssertEqual(CoachSkill.infer("Lead with the answer, then give the reasons."), .answerFirst)
        XCTAssertEqual(CoachSkill.infer("In your 1:1 with Sam, talk less and let him set the first topic."), .roomInOneOnOnes)
        XCTAssertEqual(CoachSkill.infer("When Sam talks over Jo, give the floor back to Jo by name."), .interruptions)
        XCTAssertEqual(CoachSkill.infer("Before the call ends, recap the owners."), .closingWithNextSteps)
        XCTAssertEqual(CoachSkill.infer("When Sam brings a problem, ask what he tried first."), .questions)
        XCTAssertEqual(CoachSkill.infer("The other day you were right about the vendor."), nil, "a day that is not for an item")
        XCTAssertNil(CoachSkill.infer("Offer the simple method before the full model."))
    }

    func testTheLogStartsFromTheOlderReviewsAsOneSkillForTheSameAdvice() {
        var reviews = dayAdvice.enumerated().map { i, text in
            (callID: "r\(i)", date: base.addingTimeInterval(Double(-i - 1) * day), review: review(tryNext: CoachNote(text: text, quote: "Q", at: 9, say: "By Friday.")))
        }
        reviews.append(("old", base.addingTimeInterval(-40 * day), review(tryNext: CoachNote(text: dayAdvice[0]))))
        // The oldest shape has points only, and its first one was the advice.
        reviews.append(("points", base.addingTimeInterval(-20 * day), CoachReview(headline: "H", overview: "", strengths: [],
                                                                                  improvements: [point("Give each action a date", quote: "Q")], focusProgress: nil)))
        var praiseOnly = review(didWell: CoachNote(text: "Good open."))
        praiseOnly.improving = CoachNote(text: "Longest turn 91 s, down from 152 s.")
        reviews.append(("praise", base.addingTimeInterval(-2 * day), praiseOnly))
        let seeded = AdviceRules.seed(from: reviews, now: base)
        XCTAssertEqual(seeded.count, 14, "not the review of 40 days ago, and not the praise")
        XCTAssertEqual(Set(seeded.map(\.skill)), [dates], "13 wordings and a point: one skill")
        XCTAssertTrue(seeded.allSatisfy { $0.kind == .tryNext && $0.shown && !$0.held })
        XCTAssertEqual(seeded.first?.measure, .commitmentDay, "so the count line has the share of commitments with a day")
        var profile = CoachProfile()
        profile.seed(seeded)
        XCTAssertEqual(profile.adviceVersion, CoachSkill.version)
        XCTAssertEqual(CoachPrompt.earlierAdvice(profile, record: call()).map(\.skill), [dates], "the model gets one row, not 14")
        // Advice that no rule has a key for is a skill of its own.
        let other = AdviceRules.seed(from: [("x", base, review(tryNext: CoachNote(text: "Offer the simple method before the full model.")))], now: base)
        XCTAssertEqual(CoachSkill.seedID("Give each action a date"), dates)
        XCTAssertEqual(other.map(\.skill), ["other:offer the simple method before the full model"])
    }

    // MARK: Files

    func testAReviewFromBeforeOneLineDecodesAndShowsOneLine() throws {
        let json = """
        {"headline":"Your idea set the plan","overview":"","strengths":[],"improvements":[],"feedback":{},"thread":[],"quiet":false,
         "didWell":{"text":"Your delta idea became the plan.","quote":"Just apply the percentage.","at":535},
         "improving":{"text":"Longest turn 91 s, down from 152 s."},
         "tryNext":{"text":"When asked what is next, say yours first with a day.","quote":"Let you know when I have it.","at":2900,"say":"The side forecast by Tuesday."}}
        """
        let r = try JSONDecoder.coach.decode(CoachReview.self, from: Data(json.utf8))
        XCTAssertEqual(r.version, 0)
        XCTAssertNil(r.line)
        XCTAssertEqual(r.shownLine?.kind, .tryNext)
        XCTAssertEqual(r.shownLine?.say, "The side forecast by Tuesday.")
        XCTAssertEqual(r.others.map(\.kind), [.didWell])
        XCTAssertFalse((r.others + [r.shownLine].compactMap { $0 }).contains { $0.text.contains("down from") }, "the model's trend is shown nowhere")
        XCTAssertEqual(r.improving?.text, "Longest turn 91 s, down from 152 s.", "the file keeps what it has")
        XCTAssertFalse(r.saysNothing)
    }

    func testTheOldestReviewsShowTheirFirstPointAsTheLine() {
        let r = CoachReview(headline: "H", overview: "O", strengths: [point("Led with the method", quote: "Q")],
                            improvements: [point("Date your items", quote: "Q", tryInstead: "My piece is due Tuesday.")], focusProgress: nil)
        XCTAssertEqual(r.shownLine?.text, "Date your items")
        XCTAssertEqual(r.shownLine?.say, "My piece is due Tuesday.")
        XCTAssertTrue(r.others.isEmpty, "the points are in the full review already")
    }

    func testAReviewWithOneLineRoundTripsAndAnUnknownLineIsNotAnError() throws {
        var r = settle(review(tryNext: advice()), measured: CoachMeasured(commitments: CommitmentShare(withDay: 1, total: 9))).review
        r.seenAgain = CoachNote(text: "", quote: "Q", at: 3, skill: "S")
        r.focusResult = FocusResult(callID: "c", date: base, outcome: .hit, evidence: "E", at: 1, quote: "Q")
        let data = try JSONEncoder.coach.encode(r)
        XCTAssertEqual(try JSONDecoder.coach.decode(CoachReview.self, from: data), r)
        // A later build may write a kind of line that this one does not know.
        let later = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"kind\" : \"tryNext\"", with: "\"kind\" : \"later\"")
        XCTAssertNotEqual(later, String(decoding: data, as: UTF8.self))
        let decoded = try JSONDecoder.coach.decode(CoachReview.self, from: Data(later.utf8))
        XCTAssertNil(decoded.line)
        XCTAssertEqual(decoded.headline, "H")
    }

    func testAnOlderProfileDecodesWithAnEmptyLog() throws {
        let json = #"{"summary":"S","focus":"","patterns":[{"name":"P","kind":"growth","note":"N","seen":3,"firstSeen":"2026-10-01T00:00:00Z","lastSeen":"2026-10-02T00:00:00Z","trend":"steady"}],"people":{},"history":[]}"#
        let p = try JSONDecoder.coach.decode(CoachProfile.self, from: Data(json.utf8))
        XCTAssertTrue(p.advice.isEmpty)
        XCTAssertTrue(p.observations.isEmpty)
        XCTAssertEqual(p.adviceVersion, 0)
        var next = p
        next.seed([said(dates, daysAgo: 1)])
        next.observations = [CoachObservation(callID: "a", date: base, pattern: "P", result: .missed, note: "N", quote: "Q", at: 4)]
        XCTAssertEqual(try JSONDecoder.coach.decode(CoachProfile.self, from: JSONEncoder.coach.encode(next)), next)
    }

    func testOneEntryThatDoesNotDecodeDoesNotEmptyTheLog() throws {
        var profile = CoachProfile()
        profile.advice = [said(dates, daysAgo: 3, callID: "a"), said(risk, daysAgo: 2, callID: "b"), said(dates, daysAgo: 1, callID: "c")]
        profile.observations = [CoachObservation(callID: "a", date: base, pattern: "P", result: .missed, note: "N"),
                                CoachObservation(callID: "b", date: base, pattern: "P", result: .did, note: "N")]
        // A later build wrote a kind of line and a result that this one does not know.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.coach.encode(profile)) as? [String: Any])
        var advice = try XCTUnwrap(object["advice"] as? [[String: Any]]), observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
        advice[1]["kind"] = "later"
        observations[1]["result"] = "later"
        object["advice"] = advice
        object["observations"] = observations
        let read = try JSONDecoder.coach.decode(CoachProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(read.advice.map(\.callID), ["a", "c"], "the entries that do decode stay")
        XCTAssertEqual(read.observations.map(\.callID), ["a"])
    }

    func testAFocusKeepsItsSkillWhenAnOlderBuildSavedTheNewerCopy() {
        var mac = CoachFocus(plan: "P", why: "W", metric: nil, proposed: base, skill: dates)
        mac.status = .proposed
        var phone = mac
        phone.skill = nil
        phone.measureName = nil
        phone.status = .active
        phone.updated = base.addingTimeInterval(60)
        let merged = CoachProfile.mergedFoci([mac], [phone])
        XCTAssertEqual(merged.first?.status, .active)
        XCTAssertEqual(merged.first?.skill, dates)
        XCTAssertEqual(merged.first?.measure, .commitmentDay)
    }

    // MARK: The runner

    private final class SameAdvice: Coaching, @unchecked Sendable {
        var measured: [CoachMeasured] = []
        var known: [[String]] = []
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult { fatalError("the runner passes what the app measured") }
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String], measured: CoachMeasured) async throws -> CoachResult {
            self.measured.append(measured)
            known.append(CoachPrompt.earlierAdvice(profile, record: record).map(\.skill))
            var r = CoachReview(headline: "H \(record.id)", overview: "", strengths: [],
                                improvements: [CoachPoint(title: "No day", observation: "O", quote: "Let me look at it and get back to you.", at: 1, principle: "P", tryInstead: "By Friday.")],
                                focusProgress: nil)
            r.tryNext = CoachNote(text: "When you take an item, say the day.", quote: "Let me look at it and get back to you.", at: 1, say: "By Friday.",
                                  skill: CoachSkill.commitmentDates.rawValue)
            return CoachResult(review: r, update: CoachProfileUpdate(summary: "A summary from one call.", focus: "", patterns: [
                CoachPatternUpdate(name: "Leaves items without a day", kind: .growth, note: "Took it with no day.", result: .missed, quote: "When can we see the forecast?", at: 40),
            ], people: []))
        }
    }

    private func paths(_ records: [CallRecord]) throws -> Paths {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        for r in records { try add(r, to: paths) }
        return paths
    }

    private func add(_ r: CallRecord, to paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
    }

    func testTheRunnerShowsAdviceOnceAndCountsTheCallsAfter() async throws {
        let paths = try paths([call("a", day: 0), call("b", day: 1), call("c", day: 2)])
        var book = CommitmentBook()
        book.items = (0..<6).map { Commitment(text: "T\($0)", to: nil, callID: "a", callTitle: nil, madeAt: base, due: $0 == 0 ? base : nil) }
        try book.save(to: paths.commitments)
        let coach = SameAdvice()
        let now = base.addingTimeInterval(3 * day)
        let done = await CoachRunner(paths: paths, coach: coach, owner: owner, since: .distantPast, now: { now }).run()
        XCTAssertEqual(done, 3)
        let first = try XCTUnwrap(CoachReview.load(in: paths.callDirectory("a")))
        XCTAssertEqual(first.line?.kind, .tryNext)
        XCTAssertEqual(first.line?.at, 760)
        XCTAssertEqual(first.line?.number, "1 of 6 commitments with a day (17%), last 30 days")
        XCTAssertEqual(first.improvements.count, 1)
        for id in ["b", "c"] {
            let later = try XCTUnwrap(CoachReview.load(in: paths.callDirectory(id)))
            XCTAssertNil(later.line, "the same advice after the next call is not a line")
            XCTAssertNil(later.tryNext)
            XCTAssertTrue(later.improvements.isEmpty)
            XCTAssertEqual(later.seenAgain?.at, 760)
        }
        let profile = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(profile.advice.map(\.callID), ["a", "b", "c"])
        XCTAssertEqual(profile.advice.map(\.held), [false, true, true])
        XCTAssertEqual(profile.summary, "A summary from one call.", "the first call may write a summary; the next ones do not replace it")
        XCTAssertEqual(profile.observations.count, 3)
        XCTAssertNil(profile.observations.first?.quote, "a quote of another person is not kept")
        XCTAssertEqual(coach.measured.first?.commitments, CommitmentShare(withDay: 1, total: 6))
    }

    func testTheLogHoldsFromOneRunToTheNext() async throws {
        // As the app runs the coach: a new runner after each call, with one call for each run.
        let paths = try paths([call("a", day: 0)])
        let coach = SameAdvice()
        let now = base.addingTimeInterval(3 * day)
        let one = await CoachRunner(paths: paths, coach: coach, owner: owner, since: .distantPast, now: { now }).run()
        XCTAssertEqual(one, 1)
        XCTAssertEqual(CoachReview.load(in: paths.callDirectory("a"))?.line?.kind, .tryNext)
        for (i, id) in ["b", "c"].enumerated() {
            try add(call(id, day: Double(i + 1)), to: paths)
            let next = await CoachRunner(paths: paths, coach: coach, owner: owner, since: .distantPast, now: { now }).run()
            XCTAssertEqual(next, 1)
            let review = try XCTUnwrap(CoachReview.load(in: paths.callDirectory(id)))
            XCTAssertNil(review.line, "the run after the first does not say the first run's advice again")
            XCTAssertNil(review.tryNext)
            XCTAssertEqual(review.seenAgain?.at, 760)
        }
        XCTAssertEqual(coach.known, [[], [dates], [dates]], "each later run tells the model what was said")
        let profile = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(profile.advice.map(\.callID), ["a", "b", "c"])
        XCTAssertEqual(profile.advice.map(\.held), [false, true, true], "one line, then two calls that were counted")
        XCTAssertEqual(profile.adviceVersion, CoachSkill.version)
    }

    func testTheFirstRunAfterTheUpdateKnowsWhatTheOlderReviewsSaidAndReadsThemOnce() async throws {
        let paths = try paths([call("old", day: 0), call("new", day: 1)])
        var before = review(tryNext: CoachNote(text: dayAdvice[2], quote: "Q", at: 9, say: "By Friday."))
        before.improving = CoachNote(text: "Longest turn 91 s, down from 152 s.")
        try before.save(in: paths.callDirectory("old"))
        let now = base.addingTimeInterval(2 * day)
        let done = await CoachRunner(paths: paths, coach: SameAdvice(), owner: owner, since: .distantPast, now: { now }).run()
        XCTAssertEqual(done, 1)
        XCTAssertNil(CoachReview.load(in: paths.callDirectory("new"))?.line, "the advice of the older review, in other words, is not said once more")
        var profile = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(profile.advice.map(\.callID), ["old", "new"])
        XCTAssertEqual(profile.advice.map(\.held), [false, true])
        XCTAssertEqual(profile.advice.map(\.skill), [dates, dates])
        // The owner deletes the old meeting: a later run does not read the older reviews into the log again.
        profile.forget(callID: "old")
        try profile.save(to: paths.coach)
        try add(call("next", day: 1.5), to: paths)
        _ = await CoachRunner(paths: paths, coach: SameAdvice(), owner: owner, since: .distantPast, now: { now }).run()
        XCTAssertEqual(try CoachProfile.load(from: paths.coach).advice.map(\.callID), ["new", "next"])
        XCTAssertEqual(CoachReview.load(in: paths.callDirectory("next"))?.line?.kind, .tryNext, "nothing in the log says it was said")
    }
}
