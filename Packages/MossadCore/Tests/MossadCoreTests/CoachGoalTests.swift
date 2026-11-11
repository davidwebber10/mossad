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
        return GoalOffers.roomInOneOnOnes(this: this, history: history, profile: profile, at: this.start, people: people)
    }

    private var people: MeetingFilterPeople { MeetingFilterPeople(owner: owner) }

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
        XCTAssertTrue(focus.why.contains("56% or less"), focus.why)
        XCTAssertFalse(focus.why.contains("64%"), "The numbers are the card's proof, not its reason")
    }

    func testNoOfferWithoutAFirmBaselineOrAfterAGroupCall() {
        XCTAssertNil(offer(ones("b", count: 4, from: 0) { _ in 0.7 }), "Four 1:1s do not say what is usual")
        var history = ones("b", count: 8, from: 0) { _ in 0.7 }
        history.append(meeting("group", day: 40, share: 0.5, voices: 5))
        XCTAssertNil(offer(history), "Only the review of a 1:1 offers the goal of the 1:1s")
        XCTAssertNil(offer(ones("b", count: 8, from: 0) { _ in 0.39 }), "An owner who already talks little gets no goal to talk less")
        XCTAssertEqual(offer(ones("b", count: 8, from: 0) { _ in 0.40 })?.goal?.target ?? 0, 0.32, accuracy: 0.0001, "At the floor the goal comes")
    }

    func testNoOfferWhileAGoalIsActiveOrARecentOfferWaitsOrTheOwnerSaidNo() throws {
        let history = ones("b", count: 8, from: 0) { _ in 0.66 }
        let this = history.last!
        var profile = CoachProfile()
        profile.propose(CoachFocus(plan: "Give a day", why: "", metric: nil, proposed: this.start.addingTimeInterval(-2 * day), skill: "commitment-dates"),
                        at: this.start.addingTimeInterval(-2 * day))
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: profile, at: this.start, people: people), "An offer of two days ago still waits")

        var old = CoachProfile()
        old.propose(CoachFocus(plan: "Give a day", why: "", metric: nil, proposed: this.start.addingTimeInterval(-9 * day), skill: "commitment-dates"),
                    at: this.start.addingTimeInterval(-9 * day))
        XCTAssertNotNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: old, at: this.start, people: people),
                        "An offer that waited more than 7 days with no answer has ended")

        var active = old
        active.acceptFocus(active.proposedFocus!.id, plan: nil, at: this.start.addingTimeInterval(-8 * day))
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: active, at: this.start, people: people), "One goal at a time")

        // A no to the offer: not again for 30 days. Never again: not again.
        var declined = CoachProfile()
        let first = try XCTUnwrap(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start.addingTimeInterval(-10 * day), people: people))
        declined.propose(first, at: first.proposed)
        let card = CoachFinding(id: "c|goal_offer|\(first.id)", callID: "c", date: first.proposed, kind: .goalOffer, text: first.plan, skill: room,
                                usual: "56 to 70%", focusID: first.id)
        declined.answer(card, .no, at: this.start.addingTimeInterval(-10 * day))
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start, people: people))
        XCTAssertNotNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start.addingTimeInterval(25 * day), people: people))
        declined.answer(card, .never, at: this.start)
        XCTAssertNil(GoalOffers.roomInOneOnOnes(this: this, history: history, profile: declined, at: this.start.addingTimeInterval(60 * day), people: people))
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
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(50), people: people, calendar: calendar))
        XCTAssertEqual(progress.state, .early(before: 10, since: 3))
        XCTAssertFalse(progress.reached)
        XCTAssertTrue(progress.sentence.contains("Too early to tell"), progress.sentence)
        XCTAssertEqual(progress.since.count, 3)
    }

    func testOneOnOnesThatStayInTheUsualWobbleAreNoChange() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 8, from: 38) { self.around(0.62, $0 + 3) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), people: people, calendar: calendar))
        XCTAssertEqual(progress.state, .steady, "3 points is noise, not progress")
        XCTAssertTrue(progress.sentence.hasPrefix("No clear change"), progress.sentence)
    }

    func testAClearDropToTheTargetIsProgressAndReachesIt() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 8, from: 38) { self.around(0.50, $0 + 1) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), people: people, calendar: calendar))
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
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), people: people, calendar: calendar))
        guard case .away = progress.state else { return XCTFail("\(progress.state)") }
        XCTAssertFalse(progress.reached)
        XCTAssertTrue(progress.sentence.hasPrefix("Up from"), progress.sentence)
    }

    func testOneOnOnesWithANewPersonAreNotComparedWithTheOnesBefore() throws {
        // Before: weekly 1:1s with a direct report. After: a new series with a manager, where the owner talks less.
        // Ad hoc 1:1s with no calendar title: only the person tells them apart.
        let before = (0..<10).map { meeting("b\($0)", day: Double($0) * 3.5, share: around(0.66, $0)) }
        let focus = taken(before, accepted: 36)
        let after = (0..<8).map { meeting("a\($0)", day: 38 + Double($0) * 3.5, share: around(0.40, $0), with: "Kim Park") }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), people: people, calendar: calendar))
        XCTAssertEqual(progress.state, .early(before: 0, since: 0), "A change of partner is not a change of the owner")
        XCTAssertEqual(progress.since.count, 8, "The chart still shows each 1:1")
    }

    func testGroupMeetingsAreNotPartOfTheGoal() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let groups = (0..<6).map { meeting("g\($0)", day: 38 + Double($0) * 3, share: 0.2, voices: 6) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + groups, now: date(60), people: people, calendar: calendar))
        XCTAssertEqual(progress.since.count, 0)
        XCTAssertEqual(progress.state, .early(before: 0, since: 0))
    }

    func testTheChartHasTheBaselineAsItsBandAndTheTargetInsideItsScale() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 5, from: 38) { self.around(0.62, $0) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(60), people: people, calendar: calendar))
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
        let since = focus.accepted
        let hit = try XCTUnwrap(goal.result(of: meeting("h", day: 40, share: 0.48), callID: "h", people: people, since: since))
        XCTAssertEqual(hit.outcome, .hit)
        XCTAssertEqual(hit.evidence, "You talked 48% of this 1:1 with Sam.")
        XCTAssertEqual(try XCTUnwrap(goal.result(of: meeting("m", day: 41, share: 0.71), callID: "m", people: people, since: since)).outcome, .missed)
        XCTAssertNil(goal.result(of: meeting("g", day: 42, share: 0.2, voices: 6), callID: "g", people: people, since: since), "A group is no result, not a chance")
        XCTAssertNil(goal.result(of: nil, callID: "x", people: people, since: since), "A call with no numbers has no result")
        XCTAssertNil(goal.result(of: meeting("e", day: 35, share: 0.4), callID: "e", people: people, since: since), "A 1:1 that started before the goal is not on it")
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
        XCTAssertNil(GoalProgress(focus: round, facts: [], now: date(60), people: people, calendar: calendar))
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
                                                               history: records.map { MeetingFacts(record: $0, owner: owner) }, profile: profile, at: records[4].start,
                                                               people: people))
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
        XCTAssertNil(groupReview.focusResult, "The goal is about 1:1s: a group gives no result")
        XCTAssertNotEqual(groupReview.line?.kind, .focus)

        let hit = try XCTUnwrap(CoachReview.load(in: paths.callDirectory("under")))
        XCTAssertEqual(hit.focusResult?.outcome, .hit)
        XCTAssertEqual(hit.line?.at, 0, "The model's moment of a hit stands behind a hit")
        XCTAssertEqual(hit.findings?.first?.kind, .didWell)
        XCTAssertEqual(hit.findings?.first?.usual?.hasPrefix("66% in a typical 1:1 before the goal"), true)

        let saved = try CoachProfile.load(from: paths.coach)
        XCTAssertEqual(saved.activeFocus?.results.map(\.outcome), [.missed, .hit])
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
        measured.goal = GoalProgress(focus: focus, facts: before + ones("a", count: 2, from: 38) { _ in 0.5 }, now: date(45), people: people, calendar: calendar)
        measured.goalResult = focus.goal?.result(of: meeting("x", day: 45, share: 0.5), callID: "x", people: people, since: focus.accepted)
        let text = CoachPrompt.focusText(profile, measured: measured)
        XCTAssertTrue(text.contains("Active goal"), text)
        XCTAssertTrue(text.contains("Target: 57% or less"), text)
        XCTAssertTrue(text.contains("65% in a typical 1:1"), text)
        XCTAssertTrue(text.contains("You talked 50% of this 1:1 with Sam."), text)
        XCTAssertTrue(text.contains("Too early to tell"), text)
        XCTAssertTrue(text.contains("do not restate or judge"), text)
        XCTAssertTrue(text.contains("The app's result for this call: hit"), text)
        XCTAssertTrue(text.contains("use the outcome hit"), text)

        measured.goalResult = focus.goal?.result(of: meeting("g", day: 45, share: 0.2, voices: 5), callID: "g", people: people, since: focus.accepted)
        XCTAssertTrue(CoachPrompt.focusText(profile, measured: measured).contains("not a 1:1"))
    }

    // MARK: Review fixes

    /// A talk where the owner only listens: Dana says a few words, Sam talks.
    private func listened(_ id: String, day n: Double) -> MeetingFacts {
        var f = meeting(id, day: n, share: 0.0)
        f.people[0].isMain = false
        f.people[0].values[.talkShare] = 0.01
        f.mainVoices = 1
        f.mainNames = ["Sam Carter"]
        return f
    }

    func testATalkWhereTheOwnerOnlyListensOrAMeetingWithOthersInvitedIsNotAOneOnOne() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let goal = try XCTUnwrap(focus.goal)
        XCTAssertNil(goal.result(of: listened("l", day: 40), callID: "l", people: people, since: focus.accepted), "No false \"At the target\" at 0%")
        var staff = meeting("s", day: 41, share: 0.85, with: "Kim Park")
        staff.attendees = (1...8).map { "person\($0)@example.com" }
        XCTAssertNil(goal.result(of: staff, callID: "s", people: people, since: focus.accepted), "Two voices of eight invited is not a 1:1")
        XCTAssertEqual(staff.size(people: people), .unknown)

        // Many such calls since the goal give no progress, and in the baseline they do not move the target.
        let quiet = (0..<8).map { listened("q\($0)", day: 38 + Double($0) * 2) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + quiet, now: date(60), people: people, calendar: calendar))
        XCTAssertEqual(progress.since.count, 0)
        XCTAssertFalse(progress.reached)
        let mixed = before + (0..<8).map { listened("p\($0)", day: Double($0) * 4 + 1) }
        XCTAssertEqual(offer(mixed.sorted { $0.start < $1.start } + [meeting("last", day: 33, share: 0.65)])?.goal?.target, offer(before + [meeting("last", day: 33, share: 0.65)])?.goal?.target)
    }

    func testTheSizeOfAOneOnOneIsTheRuleOfTheMeetingsFilter() {
        let one = meeting("o", day: 1, share: 0.6)
        XCTAssertEqual(one.size(people: people), .oneOnOne)
        var invited = one
        invited.attendees = ["Dana Lee", "Sam Carter"]
        XCTAssertEqual(invited.size(people: people), .oneOnOne, "The two people of the call on the invite are no one more")
        invited.attendees.append("Kim Park")
        XCTAssertEqual(invited.size(people: people), .unknown, "Kim may have listened")
    }

    func testTheModelDoesNotOfferTheAppsGoalOrAGoalThatRests() throws {
        let record = call("c", day: 40, share: 0.6)
        var result = CoachResult(review: CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil),
                                 update: CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []),
                                 proposal: CoachFocus(plan: "Let them talk", why: "w", metric: nil, proposed: record.start, skill: room))
        XCTAssertNil(CoachLineRules.settle(result, record: record, owner: owner, profile: CoachProfile(), measured: CoachMeasured()).proposal,
                     "Room in 1:1s comes from code, with its numbers")

        var profile = CoachProfile()
        var dates = CoachFocus(plan: "Say the day", why: "w", metric: nil, proposed: record.start.addingTimeInterval(-10 * day), skill: "commitment-dates")
        dates.status = .dismissed
        dates.updated = record.start.addingTimeInterval(-9 * day)
        profile.foci = [dates]
        result.proposal = CoachFocus(plan: "Give each item a day", why: "w", metric: nil, proposed: record.start, skill: "commitment-dates")
        XCTAssertNil(CoachLineRules.settle(result, record: record, owner: owner, profile: profile, measured: CoachMeasured()).proposal,
                     "A no nine days ago: not again in other words")
        XCTAssertTrue(CoachPrompt.focusText(profile, now: record.start).contains("Do not propose a focus with the skill commitment-dates, room-in-1on1s"))
        let later = call("d", day: 80, share: 0.6)
        XCTAssertNotNil(CoachLineRules.settle(result, record: later, owner: owner, profile: profile, measured: CoachMeasured()).proposal)
    }

    func testAWaitingGoalIsTheFirstCardOfTheDeckWhateverTheNewerCalls() throws {
        let history = ones("b", count: 8, from: 0) { _ in 0.66 }
        var profile = CoachProfile()
        let focus = try XCTUnwrap(offer(history))
        profile.propose(focus, at: focus.proposed)
        let empty = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        var reviews: [(callID: String, date: Date, review: CoachReview)] = [(callID: "b7", date: focus.proposed, review: empty)]
        for i in 0..<6 {
            var r = empty
            let id = "n\(i)"
            let start = focus.proposed.addingTimeInterval(Double(i + 1) * 3600)
            r.findings = ["did_well", "could_be_better"].map {
                CoachFinding(id: "\(id)|\($0)|s\(i)", callID: id, date: start, kind: CoachFinding.Kind(rawValue: $0), text: "T", skill: "s\(i)\($0)", at: 10)
            }
            reviews.append((id, start, r))
        }
        let deck = FindingRules.deck(reviews: reviews, profile: profile, now: focus.proposed.addingTimeInterval(day))
        XCTAssertEqual(deck.count, FindingRules.deckLimit)
        XCTAssertEqual(deck.first?.kind, .goalOffer)
    }

    func testOnlyAFewBeforeWithTheSamePeopleSaysSoAndOffersNoGoal() throws {
        // Three 1:1s with Sam and two with other people.
        let before = ones("b", count: 3, from: 0) { _ in 0.66 } + [meeting("x", day: 12, share: 0.7, with: "Kim Park"), meeting("y", day: 14, share: 0.6, with: "Lee Fox")]
        XCTAssertNil(offer(before), "Two single 1:1s can never show progress: no goal from them")
        var focus = CoachFocus(plan: "P", why: "W", metric: .talkShare, proposed: date(14), skill: room)
        focus.goal = CoachGoal(measure: .oneOnOneTalkShare, usual: MeetingAnalytics.Usual(before.compactMap { $0.owner?.values[.talkShare] })!, from: date(0), to: date(14), target: 0.58)
        focus.status = .active
        focus.accepted = date(15)
        let after = ones("a", count: 6, from: 16) { _ in 0.5 }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(40), people: people, calendar: calendar))
        XCTAssertEqual(progress.state, .early(before: 3, since: 6))
        XCTAssertTrue(progress.sentence.hasPrefix("Only 3 of the 1:1s before the goal"), progress.sentence)
    }

    func testTheGoalsLineIsTwoMediansThatBreakAtTheDayOfTheGoalAndAgreeWithTheSentence() throws {
        let before = ones("b", count: 10, from: 0) { self.around(0.65, $0) }
        let focus = taken(before, accepted: 36)
        let after = ones("a", count: 8, from: 38) { self.around(0.50, $0 + 1) }
        let progress = try XCTUnwrap(GoalProgress(focus: focus, facts: before + after, now: date(70), people: people, calendar: calendar))
        let pieces = Dictionary(grouping: progress.series.line, by: \.segment)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0]?.last?.date, focus.accepted)
        XCTAssertEqual(pieces[1]?.first?.date, focus.accepted?.addingTimeInterval(1))
        XCTAssertEqual(Set(progress.series.line.map(\.id)).count, progress.series.line.count, "Each step has its own date: the chart keys them by it")
        guard case .toward(_, let to) = progress.state else { return XCTFail("\(progress.state)") }
        XCTAssertEqual(progress.typicalSince ?? 0, to, accuracy: 0.0001, "The figure since is the number of the sentence")
        XCTAssertEqual(pieces[1]?.first?.value ?? 0, to, accuracy: 0.0001)
    }

    func testWithAGoalOnTheTalkShareTheCallsShareIsNotASecondCardOrATrend() throws {
        let records = (0..<8).map { call("h\($0)", day: Double($0) * 3, share: [0.66, 0.68, 0.64, 0.67, 0.65, 0.69, 0.66, 0.67][$0]) }
        let this = call("now", day: 30, share: 0.40)
        let history = (records + [this]).map { MeetingFacts(record: $0, owner: owner) }
        let without = CoachMeasured(record: this, owner: owner, history: history, commitments: [])
        XCTAssertTrue(without.standouts.contains { $0.id == "talkShare" }, "The share stands out against the usual")
        var focus = try XCTUnwrap(GoalOffers.roomInOneOnOnes(this: history[7], history: Array(history.prefix(8)), profile: CoachProfile(), at: records[7].start, people: people))
        focus.status = .active
        focus.accepted = date(25)
        let with = CoachMeasured(record: this, owner: owner, history: history, commitments: [], focus: focus, people: people)
        XCTAssertFalse(with.standouts.contains { $0.id == "talkShare" })
        XCTAssertNil(with.trend)
        XCTAssertEqual(with.goalResult?.outcome, .hit)
    }

    func testTakeItUpAgainAfterEndingOrLearningAGoal() {
        let focus = taken(ones("b", count: 8, from: 0) { _ in 0.66 }, accepted: 30)
        var profile = CoachProfile()
        profile.foci = [focus]
        profile.dismissFocus(focus.id, at: date(40))
        XCTAssertEqual(profile.goalHistory.ended.map(\.id), [focus.id])
        profile.resumeFocus(focus.id, at: date(41))
        XCTAssertEqual(profile.activeFocus?.id, focus.id)
        XCTAssertEqual(profile.activeFocus?.accepted, focus.accepted, "The goal keeps its day and its numbers")
        XCTAssertEqual(profile.activeFocus?.goal, focus.goal)
        profile.learnFocus(focus.id, at: date(50))
        profile.resumeFocus(focus.id, at: date(51))
        XCTAssertEqual(profile.activeFocus?.id, focus.id)
    }

    func testAResultOfALaterCallDoesNotUndoEndingTheGoalOnTheOtherDevice() {
        let focus = taken(ones("b", count: 8, from: 0) { _ in 0.66 }, accepted: 30)
        var phone = CoachProfile(), mac = CoachProfile()
        phone.foci = [focus]
        mac.foci = [focus]
        phone.dismissFocus(focus.id, at: date(40))
        mac.record(FocusResult(callID: "late", date: date(40.1), outcome: .hit, evidence: "E"), focus: focus.id)
        let merged = CoachProfile.mergedFoci(mac.foci, phone.foci)
        XCTAssertEqual(merged.first?.status, .dismissed)
        XCTAssertEqual(merged.first?.results.map(\.callID), ["late"], "The result stays")
    }

    func testAGoalInAShapeFromALaterBuildIsNoGoalAndTheFocusStillReads() throws {
        let json = #"{"id":"6F1E0A2C-3B7E-4E39-9C1B-2C1C7D0B5F11","plan":"P","why":"w","status":"active","proposed":"2026-10-01T10:00:00Z","results":[],"updated":"2026-10-01T10:00:00Z","goal":{"measureName":"more_questions","direction":"up"}}"#
        let focus = try JSONDecoder.coach.decode(CoachFocus.self, from: Data(json.utf8))
        XCTAssertNil(focus.goal)
        XCTAssertEqual(focus.plan, "P")
    }

    func testTheOfferReadsTheNewest20OneOnOnesOfTheLast90Days() throws {
        let old = ones("o", count: 6, from: 0) { _ in 0.9 }
        let recent = ones("r", count: 25, from: 100, every: 2) { _ in 0.6 }
        let goal = try XCTUnwrap(offer(old + recent)?.goal)
        XCTAssertEqual(goal.samples, 20)
        XCTAssertEqual(goal.median, 0.6, accuracy: 0.0001, "1:1s of more than 90 days ago are not usual now")
    }

    /// Steady 1:1s, looked at after each new one as the page does: a change is almost never said.
    func testSteadyOneOnOnesLookedAtAfterEachOneRarelyClaimAChange() throws {
        var state: UInt64 = 42
        func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        func normal() -> Double { 0.62 + 0.06 * (-2 * log(max(unit(), 1e-12))).squareRoot() * cos(2 * .pi * unit()) }
        var claims = 0
        let histories = 120
        for h in 0..<histories {
            let before = (0..<12).map { meeting("b\(h)-\($0)", day: Double($0) * 3, share: normal()) }
            let focus = taken(before, accepted: 37)
            var after: [MeetingFacts] = []
            var claimed = false
            for i in 0..<16 {
                after.append(meeting("a\(h)-\(i)", day: 38 + Double(i) * 3, share: normal()))
                guard let p = GoalProgress(focus: focus, facts: before + after, now: date(40 + Double(i) * 3), people: people, calendar: calendar) else { continue }
                if case .toward = p.state { claimed = true }
                if case .away = p.state { claimed = true }
            }
            if claimed { claims += 1 }
        }
        XCTAssertLessThanOrEqual(Double(claims) / Double(histories), 0.05, "\(claims) of \(histories) steady histories claimed a change")
    }
}
