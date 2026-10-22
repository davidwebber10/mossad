import XCTest
@testable import MossadCore

final class CoachFeedbackTests: XCTestCase {
    private func point(_ title: String) -> CoachPoint {
        CoachPoint(title: title, observation: "O", quote: "Q", at: 10, principle: "Active listening", tryInstead: "T")
    }

    private func review() -> CoachReview {
        CoachReview(headline: "H", overview: "O", strengths: [point("Framed the goal")], improvements: [point("Let Mitch talk less")], focusProgress: nil)
    }

    func testRatingAPointIsSavedOnTheReviewAndRememberedInTheProfile() {
        var r = review()
        var profile = CoachProfile()
        let fb = CoachFeedback(agree: false, note: "Letting Mitch lead is on purpose.", date: Date(timeIntervalSince1970: 5))
        r.feedback["Let Mitch talk less"] = fb
        profile.remember(fb, on: r.improvements[0], callID: "c1", title: "Mitch / David")
        XCTAssertEqual(profile.rated.count, 1)
        XCTAssertEqual(profile.rated.first?.title, "Let Mitch talk less")
        XCTAssertEqual(profile.rated.first?.agree, false)
        // Rating the same point again replaces the earlier rating.
        profile.remember(CoachFeedback(agree: true, note: nil, date: Date()), on: r.improvements[0], callID: "c1", title: "Mitch / David")
        XCTAssertEqual(profile.rated.count, 1)
        XCTAssertEqual(profile.rated.first?.agree, true)
    }

    func testRatedPointsKeepOnlyTheLatest() {
        var profile = CoachProfile()
        for i in 0..<(CoachProfile.ratedLimit + 4) {
            profile.remember(CoachFeedback(agree: true, note: nil, date: Date()), on: point("P\(i)"), callID: "c\(i)", title: "T")
        }
        XCTAssertEqual(profile.rated.count, CoachProfile.ratedLimit)
        XCTAssertEqual(profile.rated.last?.title, "P\(CoachProfile.ratedLimit + 3)")
    }

    func testGuidanceIsAddedOnceAndCanBeRemoved() {
        var profile = CoachProfile()
        profile.updateGuidance(add: ["Letting Mitch lead in 1:1s is on purpose.", " letting mitch lead in 1:1s is on purpose. ", ""], remove: [], at: Date())
        XCTAssertEqual(profile.guidance.map(\.text), ["Letting Mitch lead in 1:1s is on purpose."])
        profile.updateGuidance(add: ["Fillers do not matter to me."], remove: ["Letting Mitch lead in 1:1s is on purpose."], at: Date())
        XCTAssertEqual(profile.guidance.map(\.text), ["Fillers do not matter to me."])
    }

    func testThePromptCarriesTheGuidanceAndTheRatings() {
        var profile = CoachProfile()
        profile.updateGuidance(add: ["Fillers do not matter to me."], remove: [], at: Date())
        profile.remember(CoachFeedback(agree: false, note: "Wrong person.", date: Date()), on: point("Interrupted Ed"), callID: "c", title: "Sync")
        var r = CallRecord(id: "x", platform: .meet, bundleID: "", start: Date(), end: Date(), status: .written)
        r.speakerNames = ["me:A": "David Webber"]
        let text = CoachPrompt.user(record: r, owner: "David Webber", profile: profile)
        XCTAssertTrue(text.contains("Fillers do not matter to me."), text)
        XCTAssertTrue(text.contains("Interrupted Ed"))
        XCTAssertTrue(text.contains("Wrong person."))
        XCTAssertTrue(CoachPrompt.system(owner: "David Webber").contains("guidance"))
    }

    func testTheCoachAnswersAReplyAndUpdatesItsGuidance() async throws {
        let output = #"{"reply":"Understood. I will stop flagging that.","add_guidance":["Letting Mitch lead in 1:1s is on purpose."],"remove_guidance":[]}"#
        StubURLProtocol.handler = { _ in (200, json(["stop_reason": "end_turn", "content": [["type": "text", "text": output]]])) }
        let responder = CoachResponder(llm: AnthropicModel(apiKey: "k", session: StubURLProtocol.session()), ownerName: "David Webber")
        var r = CallRecord(id: "x", platform: .meet, bundleID: "", start: Date(), end: Date(), status: .written)
        r.calendarTitle = "Mitch / David"
        let answer = try await responder.respond(to: "That was on purpose, I let Mitch lead.", review: review(), record: r, profile: CoachProfile())
        XCTAssertEqual(answer.reply, "Understood. I will stop flagging that.")
        XCTAssertEqual(answer.add, ["Letting Mitch lead in 1:1s is on purpose."])
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requests.first).body) as! [String: Any]
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(user.contains("That was on purpose, I let Mitch lead."))
        XCTAssertTrue(user.contains("Let Mitch talk less"))
    }

    func testOldReviewsWithoutFeedbackStillLoad() throws {
        let dir = tempDirectory()
        try Data(#"{"headline":"H","overview":"O","strengths":[],"improvements":[]}"#.utf8).write(to: dir.appendingPathComponent("coach.json"))
        let r = try XCTUnwrap(CoachReview.load(in: dir))
        XCTAssertTrue(r.feedback.isEmpty)
        XCTAssertTrue(r.thread.isEmpty)
    }
}
