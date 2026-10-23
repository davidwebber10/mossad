import XCTest
@testable import MossadCore

final class CoachFocusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func proposal(_ plan: String = "When asked what's next, say your items first, each with a day.") -> CoachFocus {
        CoachFocus(plan: plan, why: "Your items left 8 calls without dates.", metric: nil, proposed: t0)
    }

    func testAProposalIsNotActiveUntilAccepted() {
        var p = CoachProfile()
        p.propose(proposal(), at: t0)
        XCTAssertNil(p.activeFocus)
        XCTAssertEqual(p.proposedFocus?.plan, "When asked what's next, say your items first, each with a day.")
        p.acceptFocus(p.proposedFocus!.id, plan: nil, at: t0.addingTimeInterval(60))
        XCTAssertEqual(p.activeFocus?.status, .active)
        XCTAssertNil(p.proposedFocus)
        XCTAssertEqual(p.focus, p.activeFocus?.plan, "The old text field mirrors the active focus for older readers")
    }

    func testAcceptingWithAnEditKeepsTheOwnersWords() {
        var p = CoachProfile()
        p.propose(proposal(), at: t0)
        p.acceptFocus(p.proposedFocus!.id, plan: "Date every commitment I make.", at: t0)
        XCTAssertEqual(p.activeFocus?.plan, "Date every commitment I make.")
    }

    func testANewProposalReplacesAnOlderOneButNotTheActiveFocus() {
        var p = CoachProfile()
        p.propose(proposal("A"), at: t0)
        p.acceptFocus(p.proposedFocus!.id, plan: nil, at: t0)
        p.propose(proposal("B"), at: t0)
        p.propose(proposal("C"), at: t0)
        XCTAssertEqual(p.activeFocus?.plan, "A")
        XCTAssertEqual(p.proposedFocus?.plan, "C")
        XCTAssertEqual(p.foci.filter { $0.status == .proposed }.count, 1)
    }

    func testAcceptingANewFocusRetiresTheOldOne() {
        var p = CoachProfile()
        p.propose(proposal("A"), at: t0)
        p.acceptFocus(p.proposedFocus!.id, plan: nil, at: t0)
        p.propose(proposal("B"), at: t0)
        p.acceptFocus(p.proposedFocus!.id, plan: nil, at: t0.addingTimeInterval(1))
        XCTAssertEqual(p.activeFocus?.plan, "B")
        XCTAssertEqual(p.foci.first { $0.plan == "A" }?.status, .dismissed)
    }

    func testResultsAreRecordedOncePerCallAndNoChanceIsNotAChance() {
        var p = CoachProfile()
        p.propose(proposal(), at: t0)
        let id = p.proposedFocus!.id
        p.acceptFocus(id, plan: nil, at: t0)
        p.record(FocusResult(callID: "c1", date: t0, outcome: .missed, evidence: "No dates"), focus: id)
        p.record(FocusResult(callID: "c1", date: t0, outcome: .hit, evidence: "Dated both"), focus: id)
        p.record(FocusResult(callID: "c2", date: t0, outcome: .noChance, evidence: "Listened"), focus: id)
        XCTAssertEqual(p.activeFocus?.results.map(\.outcome), [.hit, .noChance])
        XCTAssertEqual(p.activeFocus?.chances.map(\.callID), ["c1"])
    }

    func testFiveHitsInTheLastSixChancesMarksTheFocusLearned() {
        var p = CoachProfile()
        p.propose(proposal(), at: t0)
        let id = p.proposedFocus!.id
        p.acceptFocus(id, plan: nil, at: t0)
        let outcomes: [FocusOutcome] = [.missed, .hit, .hit, .noChance, .hit, .hit]
        for (i, o) in outcomes.enumerated() { p.record(FocusResult(callID: "c\(i)", date: t0, outcome: o, evidence: ""), focus: id) }
        XCTAssertEqual(p.activeFocus?.id, id, "4 hits is not yet learned")
        p.record(FocusResult(callID: "c9", date: t0, outcome: .hit, evidence: ""), focus: id)
        XCTAssertNil(p.activeFocus)
        XCTAssertEqual(p.foci.first?.status, .learned)
    }

    func testAResultForAnUnknownOrInactiveFocusIsIgnored() {
        var p = CoachProfile()
        p.propose(proposal(), at: t0)
        p.record(FocusResult(callID: "c1", date: t0, outcome: .hit, evidence: ""), focus: p.proposedFocus!.id)
        XCTAssertEqual(p.proposedFocus?.results, [])
    }

    func testMergeKeepsTheNewerChangeOfEachFocusAndJoinsResults() {
        var mac = CoachProfile()
        mac.propose(proposal(), at: t0)
        let id = mac.proposedFocus!.id
        var phone = mac
        phone.acceptFocus(id, plan: "Date every commitment.", at: t0.addingTimeInterval(100))
        // The Mac, which writes the coaching fields, still has the proposal; the phone's accept must win.
        let merged = mac.merged(with: phone)
        XCTAssertEqual(merged.activeFocus?.plan, "Date every commitment.")
        XCTAssertEqual(phone.merged(with: mac, takeCoaching: true).activeFocus?.plan, "Date every commitment.")

        var later = merged
        later.record(FocusResult(callID: "c1", date: t0, outcome: .hit, evidence: ""), focus: id)
        var other = merged
        other.record(FocusResult(callID: "c2", date: t0, outcome: .missed, evidence: ""), focus: id)
        XCTAssertEqual(Set(later.merged(with: other).activeFocus!.results.map(\.callID)), ["c1", "c2"])
    }

    func testOlderProfilesDecodeWithoutFociOrVoice() throws {
        let json = #"{"summary":"S","focus":"Lead with the answer","patterns":[],"people":{},"history":[]}"#
        let p = try JSONDecoder.coach.decode(CoachProfile.self, from: Data(json.utf8))
        XCTAssertEqual(p.foci, [])
        XCTAssertEqual(p.voice, .direct)
    }
}

final class CoachReviewLinesTests: XCTestCase {
    private func point(_ title: String, _ tryInstead: String?) -> CoachPoint {
        CoachPoint(title: title, observation: "O", quote: "Q", at: 12, principle: "P", tryInstead: tryInstead)
    }

    func testOlderReviewsShowTheirFirstPointsAsTheThreeLines() {
        let r = CoachReview(headline: "H", overview: "O", strengths: [point("Led with the method", nil)],
                            improvements: [point("Date your items", "My piece is due Tuesday.")], focusProgress: nil)
        XCTAssertEqual(r.lines.didWell?.text, "Led with the method")
        XCTAssertEqual(r.lines.didWell?.at, 12)
        XCTAssertNil(r.lines.improving)
        XCTAssertEqual(r.lines.tryNext?.text, "Date your items")
        XCTAssertEqual(r.lines.tryNext?.say, "My piece is due Tuesday.")
    }

    func testApplyingAReviewRecordsTheFocusResultAndAProposal() {
        var p = CoachProfile()
        p.propose(CoachFocus(plan: "A", why: "W", metric: nil, proposed: Date()), at: Date())
        let id = p.proposedFocus!.id
        p.acceptFocus(id, plan: nil, at: Date())
        var r = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        r.focusID = id
        r.focusResult = FocusResult(callID: "c1", date: Date(), outcome: .hit, evidence: "Dated both.")
        p.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: []), review: r, callID: "c1", title: "T", at: Date(),
                proposal: CoachFocus(plan: "B", why: "W", metric: nil, proposed: Date()))
        XCTAssertEqual(p.activeFocus?.results.map(\.outcome), [.hit])
        XCTAssertEqual(p.proposedFocus?.plan, "B", "A proposal can wait for the owner while a focus is active")
        XCTAssertEqual(p.history.last?.focusProgress, "Dated both.")
    }
}
