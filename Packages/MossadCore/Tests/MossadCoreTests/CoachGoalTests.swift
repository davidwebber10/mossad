import XCTest
@testable import MossadCore

/// Coach Phase 1: a goal with a number that code measures. The owner's first goal is room in 1:1s: talk less and
/// let the other person lead. The baseline, the target, the result of each call, and the progress all come from
/// the meetings' numbers; the model never says that the number moved.
final class CoachGoalTests: XCTestCase {
    private let owner = "Dana Lee"
    /// Midnight UTC.
    private let start = Date(timeIntervalSince1970: 1_790_035_200)
    private let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let room = CoachSkill.roomInOneOnOnes.rawValue

    // MARK: Helpers

    /// A meeting `n` days after `start` where the owner talked `share` of the time. Two people make a 1:1.
    private func meeting(_ id: String, day n: Double, share: Double, voices: Int = 2, with partner: String = "Sam Carter", series: String? = nil) -> MeetingFacts {
        var people = [MeetingFacts.Person(name: owner, isOwner: true, values: [.talkShare: share])]
        people.append(MeetingFacts.Person(name: partner, isOwner: false, values: [.talkShare: 1 - share]))
        for i in 2..<max(voices, 2) { people.append(MeetingFacts.Person(name: "Person \(i)", isOwner: false, values: [.talkShare: 0.1])) }
        return MeetingFacts(id: id, stamp: 0, start: start.addingTimeInterval(n * day + 10 * 3600), title: "1:1", series: series, kind: nil, tags: [],
                            voices: voices, people: people, values: [:])
    }

    /// `count` 1:1s, one every `every` days from day `from`, with the shares `value` gives for each index.
    private func ones(_ prefix: String, count: Int, from: Double, every: Double = 3.5, _ value: (Int) -> Double) -> [MeetingFacts] {
        (0..<count).map { meeting("\(prefix)\($0)", day: from + Double($0) * every, share: value($0)) }
    }

    /// Shares that wobble around a level, the same on each run.
    private func around(_ level: Double, _ i: Int) -> Double { level + [0.03, -0.04, 0.01, -0.02, 0.04, -0.01, 0.02, -0.03][i % 8] }

    private func date(_ n: Double) -> Date { start.addingTimeInterval(n * day + 10 * 3600) }

    /// The offer, made at the review of the last 1:1 of `history`.
    private func offer(_ history: [MeetingFacts], profile: CoachProfile = CoachProfile()) -> CoachFocus? {
        let this = history.max { $0.start < $1.start }!
        return GoalOffers.roomInOneOnOnes(this: this, history: history, profile: profile, at: this.start)
    }

    /// An owner who took the offered goal at `accepted` days.
    private func taken(_ history: [MeetingFacts], accepted: Double) -> CoachFocus {
        var profile = CoachProfile()
        let offered = offer(history)!
        profile.propose(offered, at: offered.proposed)
        profile.acceptFocus(offered.id, plan: nil, at: date(accepted))
        return profile.activeFocus!
    }

    // MARK: The offer

    func testTheOfferOfRoomInOneOnOnesHasTheBaselineAndATargetFromTheNumbers() throws {
        let history = ones("b", count: 12, from: 0) { self.around(0.64, $0) }
        let focus = try XCTUnwrap(offer(history))
        let goal = try XCTUnwrap(focus.goal)
        XCTAssertEqual(focus.skill, room)
        XCTAssertEqual(focus.status, .proposed)
        XCTAssertEqual(goal.measure, .oneOnOneTalkShare)
        XCTAssertEqual(goal.samples, 12)
        XCTAssertEqual(goal.median, 0.64, accuracy: 0.011)
        // The least difference that matters for a talk share, under the usual: 8 points, as a whole percent.
        XCTAssertEqual(goal.target, 0.56, accuracy: 0.0001)
        XCTAssertTrue(focus.why.contains("64%"), focus.why)
        XCTAssertTrue(focus.why.contains("56% or less"), focus.why)
    }

    func testNoOfferWithoutAFirmBaselineOrAfterAGroupCall() {
        XCTAssertNil(offer(ones("b", count: 4, from: 0) { _ in 0.7 }), "Four 1:1s do not say what is usual")
        var history = ones("b", count: 8, from: 0) { _ in 0.7 }
        history.append(meeting("group", day: 40, share: 0.5, voices: 5))
        XCTAssertNil(offer(history), "Only the review of a 1:1 offers the goal of the 1:1s")
        XCTAssertNil(offer(ones("b", count: 8, from: 0) { _ in 0.3 }), "An owner who already talks little gets no goal to talk less")
    }

    func testNoOfferWhileAGoalIsActiveOrARecentOfferWaitsOrTheOwnerSaidNo() throws {
        let history = ones("b", count: 8, from: 0) { _ in 0.66 }
        let this = history.last!
        var profile = CoachProfile()
        profile.propose(CoachFocus(plan: "Give a day", why: "", metric: nil, proposed: this.start.addingTimeInterval(-2 * day), skill: "commitment-dates"),
                        at: this.start.addingTimeInterval(-2 * day))
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: profile, at: this.start), "An offer of two days ago still waits")

        var old = CoachProfile()
        old.propose(CoachFocus(plan: "Give a day", why: "", metric: nil, proposed: this.start.addingTimeInterval(-9 * day), skill: "commitment-dates"),
                    at: this.start.addingTimeInterval(-9 * day))
        XCTAssertNotNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: old, at: this.start),
                        "An offer that waited more than 7 days with no answer has ended")

        var active = old
        active.acceptFocus(active.proposedFocus!.id, plan: nil, at: this.start.addingTimeInterval(-8 * day))
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: active, at: this.start), "One goal at a time")

        // A no to the offer: not again for 30 days. Never again: not again.
        var declined = CoachProfile()
        let first = try XCTUnwrap(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start.addingTimeInterval(-10 * day)))
        declined.propose(first, at: first.proposed)
        let card = CoachFinding(id: "c|goal_offer|\(first.id)", callID: "c", date: first.proposed, kind: .goalOffer, text: first.plan, skill: room,
                                usual: "56 to 70%", focusID: first.id)
        declined.answer(card, .no, at: this.start.addingTimeInterval(-10 * day))
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start))
        XCTAssertNotNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start.addingTimeInterval(25 * day)))
        declined.answer(card, .never, at: this.start)
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start.addingTimeInterval(60 * day)))
    }

    func testTheOfferIsACardOfItsCallWithTheNumberAndItsUsual() throws {
        let history = ones("b", count: 8, from: 0) { _ in 0.66 }
        var profile = CoachProfile()
        let focus = try XCTUnwrap(offer(history))
        profile.propose(focus, at: focus.proposed)
        let review = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        let cards = FindingRules.deck(callID: "b7", date: focus.proposed, review: review, profile: profile, now: focus.proposed.addingTimeInterval(day))
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.kind, .goalOffer)
        XCTAssertEqual(card.focusID, focus.id)
        XCTAssertTrue(card.hasProof)
        XCTAssertEqual(card.number, "66% in a typical 1:1")
        XCTAssertEqual(card.usual, "66% in your last 8 1:1s")

        // Yes on the card is the goal, with its baseline from the offer.
        profile.answer(card, .yes, at: focus.proposed.addingTimeInterval(day))
        XCTAssertEqual(profile.activeFocus?.id, focus.id)
        XCTAssertEqual(profile.activeFocus?.goal, focus.goal)
    }

    // MARK: Progress

    func testFewerOneOnOnesSinceTheGoalThanTheTestNeedsIsTooEarly() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 3, from: 38) { _ in 0.40 }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(50), calendar: calendar))
        XCTAssertEqual(progress.state, .early(meetings: 3))
        XCTAssertFalse(progress.reached)
        XCTAssertTrue(progress.sentence.contains("Too early to tell"), progress.sentence)
        XCTAssertEqual(progress.since.count, 3)
    }

    func testOneOnOnesThatStayInTheUsualWobbleAreNoChange() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 8, from: 38) { self.around(0.62, $0 + 3) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), calendar: calendar))
        XCTAssertEqual(progress.state, .steady, "3 points is noise, not progress")
        XCTAssertTrue(progress.sentence.hasPrefix("No clear change"), progress.sentence)
    }

    func testAClearDropToTheTargetIsProgressAndReachesIt() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 8, from: 38) { self.around(0.50, $0 + 1) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), calendar: calendar))
        guard case .toward(let from, let to) = progress.state else { return XCTFail("\(progress.state)") }
        XCTAssertEqual(from, 0.65, accuracy: 0.02)
        XCTAssertEqual(to, 0.50, accuracy: 0.02)
        XCTAssertTrue(progress.reached)
        XCTAssertTrue(progress.sentence.hasPrefix("Down from"), progress.sentence)
        XCTAssertTrue(progress.sentence.contains("at your target"), progress.sentence)
    }

    func testARiseIsSaidAsARiseAndIsNeverReached() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.55, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 8, from: 38) { self.around(0.72, $0 + 2) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), calendar: calendar))
        guard case .away = progress.state else { return XCTFail("\(progress.state)") }
        XCTAssertFalse(progress.reached)
        XCTAssertTrue(progress.sentence.hasPrefix("Up from"), progress.sentence)
    }

    func testOneOnOnesWithANewPersonAreNotComparedWithTheOnesBefore() throws {
        // Before: weekly 1:1s with a direct report. After: a new series with a manager, where the owner talks less.
        let before = (0..<10).map { meeting("b\($0)", day: Double($0) * 3.5, share: around(0.66, $0), series: "dana sam") }
        let focus = taken(before, accepted: 36)
        let after = (0..<8).map { meeting("a\($0)", day: 38 + Double($0) * 3.5, share: around(0.40, $0), with: "Kim Park", series: "dana kim") }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), calendar: calendar))
        XCTAssertEqual(progress.state, .early(meetings: 0), "A change of partner is not a change of the owner")
        XCTAssertEqual(progress.since.count, 8, "The chart still shows each 1:1")
    }

    func testGroupMeetingsAreNotPartOfTheGoal() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let groups = (0..<6).map { meeting("g\($0)", day: 38 + Double($0) * 3, share: 0.2, voices: 6) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + groups, now: date(60), calendar: calendar))
        XCTAssertEqual(progress.since.count, 0)
        XCTAssertEqual(progress.state, .early(meetings: 0))
    }

    func testTheChartHasTheBaselineAsItsBandAndTheTargetInsideItsScale() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 5, from: 38) { self.around(0.62, $0) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(60), calendar: calendar))
        let band = try XCTUnwrap(progress.series.usual)
        XCTAssertEqual(band.median, focus.goal!.median, accuracy: 0.0001)
        XCTAssertEqual(band.low, focus.goal!.low, accuracy: 0.0001)
        XCTAssertEqual(progress.series.points.count, 15, "The 1:1s before the goal and since")
        XCTAssertLessThanOrEqual(progress.series.scale.lower, focus.goal!.target)
        XCTAssertEqual(progress.series.metric, .talkShare)
    }

    // MARK: The result of a call

    func testTheResultOfACallComesFromItsNumberAndTheTarget() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let goal = try XCTUnwrap(focus.goal)
        let hit = try XCTUnwrap(goal.result(of: meeting("h", day: 40, share: 0.48), callID: "h"))
        XCTAssertEqual(hit.outcome, .hit)
        XCTAssertEqual(hit.evidence, "You talked 48% of this 1:1 with Sam.")
        XCTAssertEqual(try XCTUnwrap(goal.result(of: meeting("m", day: 41, share: 0.71), callID: "m")).outcome, .missed)
        XCTAssertEqual(try XCTUnwrap(goal.result(of: meeting("g", day: 42, share: 0.2, voices: 6), callID: "g")).outcome, .noChance)
        XCTAssertNil(goal.result(of: nil, callID: "x"), "A call with no numbers has no result")
    }

    func testAMeasuredGoalIsNeverLearnedFromTheModelsHits() {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        var profile = CoachProfile()
        let offered = offer(before)!
        profile.propose(offered, at: offered.proposed)
        profile.acceptFocus(offered.id, plan: nil, at: date(36))
        for i in 0..<6 { profile.record(FocusResult(callID: "c\(i)", date: date(37 + Double(i)), outcome: .hit, evidence: "Hit"), focus: offered.id) }
        XCTAssertEqual(profile.activeFocus?.id, offered.id, "Six hits in a row do not end a goal that the app measures")
        profile.learnFocus(offered.id, at: date(60))
        XCTAssertEqual(profile.goalHistory.finished.map(\.id), [offered.id], "The owner says when it is learned")
        XCTAssertNil(profile.activeFocus)
    }

    func testTheReviewDateIsSixWeeksAfterTheGoalWasTaken() {
        let focus = taken(ones("b", count: 8, from: 0) { _ in 0.66 }, accepted: 30)
        XCTAssertEqual(focus.reviewDate, date(30).addingTimeInterval(42 * day))
    }

    // MARK: Files

    func testAFocusFromBeforeGoalsDecodesAndAGoalSurvivesAMergeWithAnOlderCopy() throws {
        let old = #"{"id":"6F1E0A2C-3B7E-4E39-9C1B-2C1C7D0B5F11","plan":"Say the day","why":"w","status":"active","proposed":"2026-10-01T10:00:00Z","results":[],"updated":"2026-10-01T10:00:00Z"}"#
        let decoded = try JSONDecoder.coach.decode(CoachFocus.self, from: Data(old.utf8))
        XCTAssertNil(decoded.goal)
        XCTAssertNil(decoded.reviewDate)

        let focus = taken(ones("b", count: 8, from: 0) { _ in 0.66 }, accepted: 30)
        var olderCopy = focus
        olderCopy.goal = nil
        olderCopy.updated = focus.updated.addingTimeInterval(60)
        let merged = CoachProfile.mergedFoci([focus], [olderCopy])
        XCTAssertEqual(merged.first?.goal, focus.goal, "A copy saved by a build from before goals keeps the goal of the other copy")

        let round = try JSONDecoder.coach.decode(CoachFocus.self, from: JSONEncoder.coach.encode(focus))
        XCTAssertEqual(round, focus)
    }

    func testAGoalWithAMeasureFromALaterBuildHasNoMeasureHere() throws {
        var focus = taken(ones("b", count: 8, from: 0) { _ in 0.66 }, accepted: 30)
        focus.goal?.measureName = "a_later_measure"
        let round = try JSONDecoder.coach.decode(CoachFocus.self, from: JSONEncoder.coach.encode(focus))
        XCTAssertNil(round.goal?.measure)
        XCTAssertNil(GoalProgress(focus: round, facts: [], now: date(60), calendar: calendar))
    }

    // MARK: The review of a call

    /// A 1:1 of Dana and Sam on day `n` where Dana talked `share` of 100 seconds of speech.
    private func call(_ id: String, day n: Double, share: Double, quote: String = "What do you think we should do first?") -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: date(n), end: date(n).addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": owner, "them:A": "Sam Carter"]
        r.utterances = [
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 100 * share, text: quote),
            Utterance(track: .them, speakerLabel: "A", start: 100 * share + 1, end: 101, text: "Here is how I see it."),
        ]
        return r
    }

    private final class Stub: Coaching, @unchecked Sendable {
        /// The focus that the model saw for each call, and the outcome it gives for the active focus.
        var seen: [(proposed: CoachFocus?, active: CoachFocus?, measured: CoachMeasured)] = []
        var outcome = FocusOutcome.hit
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?) async throws -> CoachResult { fatalError("not used") }
        func review(record: CallRecord, profile: CoachProfile, tone: VoiceTone?, people: [String], measured: CoachMeasured) async throws -> CoachResult {
            seen.append((profile.proposedFocus, profile.activeFocus, measured))
            var r = CoachReview(headline: "H \(record.id)", overview: "", strengths: [], improvements: [], focusProgress: nil)
            if let focus = profile.activeFocus {
                r.focusID = focus.id
                r.focusResult = FocusResult(callID: record.id, date: record.start, outcome: outcome, evidence: "The model's view.", at: 0,
                                            quote: "What do you think we should do first?")
            }
            return CoachResult(review: r, update: CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []))
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

    func testTheReviewOfAOneOnOneOffersTheGoalOnceTheBaselineIsFirmAndTheModelIsTold() async throws {
        let records = (0..<6).map { call("c\($0)", day: Double($0) * 3, share: 0.66) }
        let paths = try paths(records)
        let stub = Stub()
        let now = date(20)
        let done = await CoachRunner(paths: paths, coach: stub, owner: owner, since: .distantPast, now: { now }).run()
        XCTAssertEqual(done, 6)
        XCTAssertEqual(stub.seen.prefix(4).compactMap(\.proposed).count, 0, "Four 1:1s do not say what is usual")
        let offered = try XCTUnwrap(stub.seen[4].proposed, "The fifth 1:1 makes the baseline firm: the model is told the goal waits")
        XCTAssertEqual(offered.skill, room)
        XCTAssertEqual(offered.proposed, records[4].start)
        XCTAssertEqual(stub.seen[5].proposed?.id, offered.id, "The offer waits; the next call makes no second one")
        let profile = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(profile.proposedFocus?.id, offered.id)
        XCTAssertEqual(profile.proposedFocus?.goal?.samples, 5)
        let review = try XCTUnwrap(CoachReview.load(in: paths.callDirectory("c4")))
        let cards = FindingRules.deck(callID: "c4", date: records[4].start, review: review, profile: profile, now: date(20))
        XCTAssertEqual(cards.first?.kind, .goalOffer)
        XCTAssertEqual(cards.first?.number, "66% in a typical 1:1")
    }

    func testWithTheGoalTakenEachOneOnOneGetsItsResultFromItsNumberNotFromTheModel() async throws {
        let records = (0..<5).map { call("b\($0)", day: Double($0) * 3, share: 0.66) }
        let paths = try paths(records)
        var profile = CoachProfile()
        let offered = try XCTUnwrap(GoalOffers.roomInOneOnOnes(this: MeetingFacts(record: records[4], owner: owner),
                                                               history: records.map { MeetingFacts(record: $0, owner: owner) }, profile: profile, at: records[4].start))
        profile.propose(offered, at: offered.proposed)
        profile.acceptFocus(offered.id, plan: nil, at: date(14))
        try profile.save(to: paths.coach)
        for r in records { try CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil).save(in: paths.callDirectory(r.id)) }

        // The model says hit; the 1:1's number is over the target.
        let over = call("over", day: 15, share: 0.75)
        var group = call("group", day: 16, share: 0.3)
        group.speakerNames["them:B"] = "Kim Park"
        group.utterances.append(Utterance(track: .them, speakerLabel: "B", start: 102, end: 160, text: "And from my side, the numbers."))
        let under = call("under", day: 17, share: 0.45)
        for r in [over, group, under] {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        let stub = Stub()
        stub.outcome = .hit
        let now = date(20)
        let done = await CoachRunner(paths: paths, coach: stub, owner: owner, since: date(15), now: { now }).run()
        XCTAssertEqual(done, 3)

        let missed = try XCTUnwrap(CoachReview.load(in: paths.callDirectory("over")))
        XCTAssertEqual(missed.focusResult?.outcome, .missed, "The number decides, not the model")
        XCTAssertEqual(missed.line?.kind, .focus)
        XCTAssertEqual(missed.line?.text, "You talked 75% of this 1:1 with Sam.")
        XCTAssertEqual(missed.line?.number?.hasPrefix("Target 58% or less; 66% in a typical 1:1 before the goal"), true, missed.line?.number ?? "")
        XCTAssertNil(missed.line?.at, "The model's moment of a hit does not stand behind a miss")

        let groupReview = try XCTUnwrap(CoachReview.load(in: paths.callDirectory("group")))
        XCTAssertEqual(groupReview.focusResult?.outcome, .noChance, "The goal is about 1:1s")
        XCTAssertNotEqual(groupReview.line?.kind, .focus)

        let hit = try XCTUnwrap(CoachReview.load(in: paths.callDirectory("under")))
        XCTAssertEqual(hit.focusResult?.outcome, .hit)
        XCTAssertEqual(hit.line?.at, 0, "The model's moment of a hit stands behind a hit")
        XCTAssertEqual(hit.findings?.first?.kind, .didWell)
        XCTAssertEqual(hit.findings?.first?.usual?.hasPrefix("66% in a typical 1:1 before the goal"), true)

        let saved = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(saved.activeFocus?.results.map(\.outcome), [.missed, .noChance, .hit])
        XCTAssertNotNil(stub.seen.last?.measured.goal, "The review knows the progress of the goal")
        XCTAssertEqual(stub.seen.last?.measured.goalResult?.outcome, .hit)
    }

    func testThePromptGivesTheGoalItsNumbersAndTheProgressFromTheApp() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        var profile = CoachProfile()
        let offered = try XCTUnwrap(offer(before))
        profile.propose(offered, at: offered.proposed)
        profile.acceptFocus(offered.id, plan: nil, at: date(36))
        let focus = try XCTUnwrap(profile.activeFocus)
        var measured = CoachMeasured()
        measured.goal = GoalProgress(focus: focus, facts: before + ones("a", count: 2, from: 38) { _ in 0.5 }, now: date(45), calendar: calendar)
        measured.goalResult = focus.goal?.result(of: meeting("x", day: 45, share: 0.5), callID: "x")
        let text = CoachPrompt.focusText(profile, measured: measured)
        XCTAssertTrue(text.contains("Active goal"), text)
        XCTAssertTrue(text.contains("Target: 57% or less"), text)
        XCTAssertTrue(text.contains("65% in a typical 1:1"), text)
        XCTAssertTrue(text.contains("You talked 50% of this 1:1 with Sam."), text)
        XCTAssertTrue(text.contains("Too early to tell"), text)
        XCTAssertTrue(text.contains("do not restate or judge"), text)

        measured.goalResult = focus.goal?.result(of: meeting("g", day: 45, share: 0.2, voices: 5), callID: "g")
        XCTAssertTrue(CoachPrompt.focusText(profile, measured: measured).contains("not a 1:1"))
    }
}
