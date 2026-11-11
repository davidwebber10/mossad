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

    private let giveADay = "Give a day with each commitment"

    private func advice(_ quote: String = "Let me look at it and get back to you.", at: TimeInterval? = 760, skill: String? = nil,
                        text: String = "When you take an item, say the day.", measure: CoachMeasure? = nil) -> CoachNote {
        CoachNote(text: text, quote: quote, at: at, say: "I will send it by Friday.", skill: skill ?? giveADay, measure: measure)
    }

    private func said(_ skill: String, daysAgo: Double, callID: String = "old", kind: CoachLine.Kind = .tryNext, held: Bool = false,
                      text: String = "Say the day.", measure: CoachMeasure? = nil) -> CoachAdvice {
        CoachAdvice(callID: callID, date: base.addingTimeInterval(-daysAgo * day), kind: kind, skill: skill, text: text, at: 5, measure: measure, held: held)
    }

    private func settle(_ review: CoachReview, _ record: CallRecord? = nil, profile: CoachProfile = CoachProfile(),
                        measured: CoachMeasured = CoachMeasured(), patterns: [CoachPatternUpdate] = []) -> CoachResult {
        CoachLineRules.settle(CoachResult(review: review, update: CoachProfileUpdate(summary: "", focus: "", patterns: patterns, people: [])),
                              record: record ?? call(), owner: owner, profile: profile, measured: measured)
    }

    // MARK: Proof

    func testAdviceWithTheOwnersOwnWordsBecomesTheLineAtThatMoment() {
        let out = settle(review(tryNext: advice(at: 700), didWell: CoachNote(text: "You named the risk.", quote: "My read is that the vendor price holds", at: 900, skill: "Name the risk")))
        XCTAssertEqual(out.review.line?.kind, .tryNext)
        XCTAssertEqual(out.review.line?.text, "When you take an item, say the day.")
        XCTAssertEqual(out.review.line?.at, 760, "the time is the line's, as code found it")
        XCTAssertEqual(out.review.line?.say, "I will send it by Friday.")
        XCTAssertEqual(out.review.line?.skill, giveADay)
        XCTAssertEqual(out.review.version, CoachReview.currentVersion)
        XCTAssertEqual(out.advice.map(\.kind), [.tryNext, .didWell], "what the review says is what the log keeps")
        XCTAssertEqual(out.advice.map(\.held), [false, false])
        XCTAssertEqual(out.review.others.map(\.kind), [.didWell], "the rest waits in the full review")
    }

    func testAQuoteThatIsNotTheOwnersOwnLineIsNoProof() {
        // Sam said it, and the second quote is in no line at all.
        let out = settle(review(tryNext: advice("When can we see the forecast?", at: 40),
                                didWell: CoachNote(text: "You closed well.", quote: "We agreed on every owner and every date.", at: 900, skill: "Close")))
        XCTAssertNil(out.review.line)
        XCTAssertNil(out.review.tryNext, "advice without proof is not kept, not in the full review also")
        XCTAssertNil(out.review.didWell)
        XCTAssertEqual(out.unproven, 2)
        XCTAssertTrue(out.advice.isEmpty, "a line without proof was not said")
    }

    func testAQuietReviewHasNoLine() {
        let out = settle(review(quiet: true))
        XCTAssertNil(out.review.line)
        XCTAssertNil(out.review.shownLine)
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

    // MARK: No repeats

    func testTheSameAdviceDoesNotComeBackInThirtyDays() {
        var profile = CoachProfile()
        profile.advice = [said(giveADay, daysAgo: 12)]
        let out = settle(review(tryNext: advice(), didWell: CoachNote(text: "You named the risk.", quote: "My read is that the vendor price holds", at: 900, skill: "Name the risk")),
                         profile: profile)
        XCTAssertEqual(out.review.line?.kind, .didWell, "the next thing with proof takes the line")
        XCTAssertNil(out.review.tryNext, "the advice is not written again, not in the full review also")
        XCTAssertEqual(out.review.seenAgain?.at, 760, "the moment stays, as evidence")
        XCTAssertEqual(out.advice.filter(\.held).map(\.skill), [giveADay], "the log counts it")
    }

    func testAdviceComesBackAfterThirtyDays() {
        var profile = CoachProfile()
        profile.advice = [said(giveADay, daysAgo: 31)]
        XCTAssertEqual(settle(review(tryNext: advice()), profile: profile).review.line?.kind, .tryNext)
    }

    func testAdviceIsTheSameByItsSkillItsMeasureOrItsWords() {
        func repeats(_ note: CoachNote, _ entry: CoachAdvice) -> Bool {
            AdviceRules.earlier(kind: .tryNext, skill: note.skill ?? "", text: note.text, measure: note.measure, in: [entry], callID: "c", date: base) != nil
        }
        XCTAssertTrue(repeats(advice(skill: "give a day, with each commitment!"), said(giveADay, daysAgo: 3)), "case and punctuation do not make it new")
        XCTAssertTrue(repeats(advice(skill: "Date what you promise", measure: .commitmentDay), said("Close with dates", daysAgo: 3, measure: .commitmentDay)))
        XCTAssertTrue(repeats(advice(skill: "Dates", text: "When you take an item, say the day you will send it."),
                              said("Another name", daysAgo: 3, text: "When you take an item, say the day.")))
        XCTAssertFalse(repeats(advice(skill: "Ask before you tell", text: "When Sam brings a problem, ask what he tried first."), said(giveADay, daysAgo: 3)))
        XCTAssertFalse(repeats(advice(), said(giveADay, daysAgo: 3, callID: "c")), "a call reviewed again does not repeat itself")
        XCTAssertFalse(repeats(advice(), said(giveADay, daysAgo: 3, held: true)), "only a line that was said counts as said")
    }

    func testPraiseForTheAdvisedSkillIsNotARepeatButTheSamePraiseIs() {
        var profile = CoachProfile()
        profile.advice = [said(giveADay, daysAgo: 5)]
        let praise = CoachNote(text: "You gave a day: Friday for the forecast.", quote: "I will send the forecast to finance.", at: 10, skill: giveADay)
        XCTAssertEqual(settle(review(didWell: praise), profile: profile).review.line?.kind, .didWell, "the owner did what was advised: that is news")
        profile.advice.append(said(giveADay, daysAgo: 2, callID: "older", kind: .didWell))
        let again = settle(review(didWell: praise), profile: profile)
        XCTAssertNil(again.review.line)
        XCTAssertNil(again.review.didWell)
    }

    func testTheAcceptedFocusIsTheLineOnEachCallThatGaveAChance() {
        var profile = CoachProfile()
        profile.propose(CoachFocus(plan: "When you take an item, say the day.", why: "W", metric: nil, proposed: base), at: base)
        let id = profile.proposedFocus!.id
        profile.acceptFocus(id, plan: nil, at: base)
        profile.record(FocusResult(callID: "a", date: base.addingTimeInterval(-2 * day), outcome: .hit, evidence: "E"), focus: id)
        profile.record(FocusResult(callID: "b", date: base.addingTimeInterval(-day), outcome: .missed, evidence: "E"), focus: id)
        profile.advice = [said("When you take an item, say the day.", daysAgo: 1, callID: "b", kind: .focus)]
        var r = review(tryNext: advice(skill: "Ask before you tell"))
        r.focusID = id
        r.focusResult = FocusResult(callID: "c", date: base, outcome: .hit, evidence: "You gave Friday for the forecast.", at: 10)
        let out = settle(r, profile: profile)
        XCTAssertEqual(out.review.line?.kind, .focus, "the owner's goal comes first, and it may come each call")
        XCTAssertEqual(out.review.line?.outcome, .hit)
        XCTAssertEqual(out.review.line?.at, 10)
        XCTAssertEqual(out.review.line?.number, "2 of 3 chances")
        XCTAssertEqual(out.review.others.map(\.kind), [.tryNext])

        r.focusResult = FocusResult(callID: "c", date: base, outcome: .noChance, evidence: "No items came up.")
        XCTAssertEqual(settle(r, profile: profile).review.line?.kind, .tryNext, "no chance is no news")
    }

    func testAdviceThatMoreCallsShowComesBackAsACountNotAsAdvice() {
        var profile = CoachProfile()
        profile.advice = [said(giveADay, daysAgo: 9, callID: "first", measure: .commitmentDay)]
        var r = review()
        r.seenAgain = CoachNote(text: "", quote: "Let me look at it and get back to you.", at: 760, skill: giveADay)
        // One more call: counted, not said.
        let one = settle(r, profile: profile)
        XCTAssertNil(one.review.line)
        XCTAssertEqual(one.advice.map(\.held), [true])
        // The third call in more than a week: the count, with the moment and the number.
        profile.advice += [said(giveADay, daysAgo: 6, callID: "x", held: true), said(giveADay, daysAgo: 2, callID: "y", held: true)]
        let commitments = CommitmentShare(withDay: 4, total: 33)
        let three = settle(r, profile: profile, measured: CoachMeasured(commitments: commitments))
        XCTAssertEqual(three.review.line?.kind, .again)
        XCTAssertEqual(three.review.line?.at, 760)
        XCTAssertEqual(three.review.line?.skill, giveADay)
        XCTAssertNil(three.review.line?.say, "the count does not give the advice again")
        XCTAssertTrue(three.review.line?.text.contains("3 more calls") == true, three.review.line?.text ?? "")
        XCTAssertEqual(three.review.line?.number, commitments.text)
        XCTAssertEqual(three.advice.map(\.held), [false], "a count that was shown starts the count again")
        // Three calls in three days are not a week.
        profile.advice = [said(giveADay, daysAgo: 3, callID: "first"), said(giveADay, daysAgo: 2, callID: "x", held: true), said(giveADay, daysAgo: 1, callID: "y", held: true)]
        XCTAssertNil(settle(r, profile: profile).review.line)
    }

    func testSeenAgainNeedsEarlierAdviceAndTheOwnersWords() {
        var r = review()
        r.seenAgain = CoachNote(text: "", quote: "Let me look at it and get back to you.", at: 760, skill: giveADay)
        let none = settle(r)
        XCTAssertNil(none.review.seenAgain, "nothing was said before")
        XCTAssertTrue(none.advice.isEmpty)
        var profile = CoachProfile()
        profile.advice = [said(giveADay, daysAgo: 9)]
        r.seenAgain?.quote = "When can we see the forecast?"
        XCTAssertTrue(settle(r, profile: profile).advice.isEmpty, "Sam's words are not the owner's moment")
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

    func testAdviceComesBeforeANumberAndATrendBeforeAdvice() {
        let number = CoachMeasured.Standout(id: "talkShare", text: "talked 81% of the time; usually 62 to 70% in your 1:1s with Sam", at: nil)
        XCTAssertEqual(settle(review(tryNext: advice()), measured: CoachMeasured(standouts: [number])).review.line?.kind, .tryNext)
        let trend = CoachTrend(id: "oneOnOneShare", text: "You leave more room in your 1:1s.", proof: "You talked 55% in your last 5; 62 to 70% in the 8 before.")
        let out = settle(review(tryNext: advice()), measured: CoachMeasured(standouts: [number], trend: trend))
        XCTAssertEqual(out.review.line?.kind, .progress)
        XCTAssertEqual(out.review.line?.number, trend.proof)
        XCTAssertEqual(out.review.others.map(\.kind), [.tryNext])
    }

    func testTheShareOfCommitmentsWithADayStandsNextToAdviceAboutIt() {
        let share = CommitmentShare(withDay: 4, total: 33)
        let out = settle(review(tryNext: advice(measure: .commitmentDay)), measured: CoachMeasured(commitments: share))
        XCTAssertEqual(out.review.line?.number, "4 of your 33 commitments in the last 30 days have a day (12%)")
        XCTAssertEqual(out.advice.first?.measure, .commitmentDay)
        XCTAssertNil(settle(review(tryNext: advice()), measured: CoachMeasured(commitments: share)).review.line?.number, "only where the coach speaks of it")
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

    func testMoreRoomInOneOnOnesIsATrendOnlyInAOneOnOne() {
        func facts(_ id: String, daysAgo: Double, share: Double, with other: String = "Sam Carter", third: Bool = false) -> MeetingFacts {
            var people = [MeetingFacts.Person(name: owner, isOwner: true, values: [.talkShare: share]),
                          MeetingFacts.Person(name: other, isOwner: false, values: [.talkShare: 1 - share])]
            if third { people.append(MeetingFacts.Person(name: "Jo Park", isOwner: false, values: [.talkShare: 0.1])) }
            return MeetingFacts(id: id, stamp: 0, start: base.addingTimeInterval(-daysAgo * day), title: id, series: nil, kind: nil, tags: [],
                                voices: people.count, people: people, values: [:])
        }
        let shares = [0.66, 0.68, 0.64, 0.70, 0.67, 0.65, 0.69, 0.66, 0.55, 0.54, 0.57, 0.52]
        let history = shares.enumerated().map { i, s in facts("h\(i)", daysAgo: Double(shares.count - i) * 3, share: s, with: i % 2 == 0 ? "Sam Carter" : "Jo Park") }
        let trend = CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.56), history: history)
        XCTAssertEqual(trend?.id, "oneOnOneShare")
        XCTAssertEqual(trend?.proof, "You talked 55% in your last 5; 64 to 70% in the 8 before.")
        XCTAssertNil(CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.2, third: true), history: history), "a group is not a 1:1")
        let up = shares.map { 1.2 - $0 }.enumerated().map { i, s in facts("h\(i)", daysAgo: Double(shares.count - i) * 3, share: s) }
        XCTAssertNil(CoachTrend.oneOnOneShare(this: facts("now", daysAgo: 0, share: 0.66), history: up), "more talk is not more room")
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
    }

    func testApplyingAReviewLogsItsAdviceOncePerCall() {
        var profile = CoachProfile()
        let first = [CoachAdvice(callID: "c", date: base, kind: .tryNext, skill: giveADay, text: "T", at: 1, measure: nil, held: false)]
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "c", title: "T", at: base, advice: first)
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "c", title: "T", at: base,
                      advice: [CoachAdvice(callID: "c", date: base, kind: .didWell, skill: "Other", text: "T", at: 1, measure: nil, held: false)])
        XCTAssertEqual(profile.advice.map(\.skill), ["Other"])
    }

    func testADeletedMeetingLeavesNothingInTheMemory() {
        var profile = CoachProfile()
        profile.advice = [said(giveADay, daysAgo: 1, callID: "gone"), said("Other", daysAgo: 1, callID: "stays")]
        profile.observations = [CoachObservation(callID: "gone", date: base, pattern: "P", result: .missed, note: "N", quote: "My words", at: 3)]
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: review(), callID: "gone", title: "T", at: base)
        profile.forget(callID: "gone")
        XCTAssertEqual(profile.advice.map(\.callID), ["stays"])
        XCTAssertTrue(profile.observations.isEmpty)
        XCTAssertTrue(profile.history.isEmpty)
    }

    func testTheLogStartsFromTheReviewsOfTheLastThirtyDays() {
        var old = review(tryNext: CoachNote(text: "When you take an item, say the day.", quote: "Q", at: 9, say: "By Friday."))
        old.didWell = CoachNote(text: "Good open.")
        let seeded = AdviceRules.seed(from: [("a", base.addingTimeInterval(-40 * day), old), ("b", base.addingTimeInterval(-3 * day), old)], now: base)
        XCTAssertEqual(seeded.map(\.callID), ["b"])
        XCTAssertEqual(seeded.first?.kind, .tryNext)
        XCTAssertEqual(seeded.first?.skill, "When you take an item, say the day.", "an older review has no skill name: the advice is its own name")
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
    }

    func testTheOldestReviewsShowTheirFirstPointAsTheLine() {
        let point = CoachPoint(title: "Date your items", observation: "O", quote: "Q", at: 12, principle: "P", tryInstead: "My piece is due Tuesday.")
        let r = CoachReview(headline: "H", overview: "O", strengths: [CoachPoint(title: "Led with the method", observation: "O", quote: "Q", at: 3, principle: "P", tryInstead: nil)],
                            improvements: [point], focusProgress: nil)
        XCTAssertEqual(r.shownLine?.text, "Date your items")
        XCTAssertEqual(r.shownLine?.say, "My piece is due Tuesday.")
        XCTAssertTrue(r.others.isEmpty, "the points are in the full review already")
    }

    func testAReviewWithOneLineRoundTripsAndAnUnknownLineIsNotAnError() throws {
        var r = settle(review(tryNext: advice(measure: .commitmentDay)), measured: CoachMeasured(commitments: CommitmentShare(withDay: 1, total: 9))).review
        r.seenAgain = CoachNote(text: "", quote: "Q", at: 3, skill: "S")
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
        var next = p
        next.advice = [said(giveADay, daysAgo: 1, measure: .commitmentDay)]
        next.observations = [CoachObservation(callID: "a", date: base, pattern: "P", result: .missed, note: "N", quote: "Q", at: 4)]
        XCTAssertEqual(try JSONDecoder.coach.decode(CoachProfile.self, from: JSONEncoder.coach.encode(next)), next)
    }

    // MARK: The runner

    private final class SameAdvice: Coaching, @unchecked Sendable {
        var measured: [CoachMeasured] = []
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult { fatalError("the runner passes what the app measured") }
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String], measured: CoachMeasured) async throws -> CoachResult {
            self.measured.append(measured)
            var r = CoachReview(headline: "H \(record.id)", overview: "", strengths: [], improvements: [], focusProgress: nil)
            r.tryNext = CoachNote(text: "When you take an item, say the day.", quote: "Let me look at it and get back to you.", at: 1, say: "By Friday.",
                                  skill: "Say the day", measure: .commitmentDay)
            return CoachResult(review: r, update: CoachProfileUpdate(summary: "A summary from one call.", focus: "", patterns: [
                CoachPatternUpdate(name: "Leaves items without a day", kind: .growth, note: "Took it with no day.", result: .missed, quote: "When can we see the forecast?", at: 40),
            ], people: []))
        }
    }

    private func paths(_ records: [CallRecord]) throws -> Paths {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        for r in records {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        return paths
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
        XCTAssertEqual(first.line?.number, "1 of your 6 commitments in the last 30 days have a day (17%)")
        for id in ["b", "c"] {
            let later = try XCTUnwrap(CoachReview.load(in: paths.callDirectory(id)))
            XCTAssertNil(later.line, "the same advice after the next call is not a line")
            XCTAssertNil(later.tryNext)
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

    func testTheFirstRunAfterTheUpdateKnowsWhatTheOlderReviewsSaid() async throws {
        let paths = try paths([call("old", day: 0), call("new", day: 1)])
        var before = review(tryNext: CoachNote(text: "When you take an item, say the day.", quote: "Q", at: 9, say: "By Friday."))
        before.improving = CoachNote(text: "Longest turn 91 s, down from 152 s.")
        try before.save(in: paths.callDirectory("old"))
        let now = base.addingTimeInterval(2 * day)
        let done = await CoachRunner(paths: paths, coach: SameAdvice(), owner: owner, since: .distantPast, now: { now }).run()
        XCTAssertEqual(done, 1)
        XCTAssertNil(CoachReview.load(in: paths.callDirectory("new"))?.line, "the advice of the older review is not said once more")
        let profile = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(profile.advice.map(\.callID), ["old", "new"])
        XCTAssertEqual(profile.advice.map(\.held), [false, true])
    }

    func testTheLineIsShort() {
        let line = settle(review(tryNext: advice())).review.line
        XCTAssertLessThanOrEqual(line?.words ?? 99, 35)
    }
}
