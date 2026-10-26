import XCTest
@testable import MossadCore

/// The coach's questions: conclusions it asks the owner to confirm (docs/superpowers/specs/2026-10-26-design-overhaul.md, part 1).
final class CoachQuestionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func question(_ statement: String, _ kind: CoachQuestion.Kind = .relationship, call: String? = "c1") -> CoachQuestion {
        CoachQuestion(statement: statement, kind: kind, evidence: "“I'll check with Mitch” (12:40)", callID: call, at: 760, asked: t0)
    }

    func testANewQuestionIsAskedOnceAndANoIsNeverAskedAgain() {
        var p = CoachProfile()
        p.ask([question("Mitch reports to you."), question("The Monday call is a status update.", .meetingPurpose)])
        XCTAssertEqual(p.openQuestions.count, 2)
        p.ask([question("mitch reports to you")])
        XCTAssertEqual(p.questions.count, 2, "the same statement, ignoring case and the final period")
        p.answer(p.questions[0].id, .rejected, note: nil, at: t0.addingTimeInterval(60))
        p.ask([question("Mitch reports to you.")])
        XCTAssertEqual(p.questions.count, 2)
        XCTAssertEqual(p.openQuestions.map(\.statement), ["The Monday call is a status update."])
    }

    func testAtMostFiveQuestionsWaitAtOnce() {
        var p = CoachProfile()
        p.ask((1...7).map { question("Fact \($0).") })
        XCTAssertEqual(p.openQuestions.count, CoachProfile.openQuestionLimit)
    }

    func testAYesBecomesAFactAndANotQuiteKeepsTheOwnersWords() {
        var p = CoachProfile()
        p.ask([question("Mitch reports to you."), question("Ben approves every date.", .preference)])
        p.answer(p.questions[0].id, .confirmed, note: nil, at: t0)
        p.answer(p.questions[1].id, .corrected, note: "Legal approves dates first.", at: t0)
        XCTAssertEqual(p.facts(.relationship).map(\.text), ["Mitch reports to you."])
        XCTAssertEqual(p.facts(.context).map(\.text), ["Legal approves dates first."])
        XCTAssertEqual(p.questions[1].note, "Legal approves dates first.")
    }

    func testAnAnswerOnEitherDeviceWinsByItsDate() {
        var mac = CoachProfile()
        mac.ask([question("Mitch reports to you.")])
        var phone = mac
        phone.answer(phone.questions[0].id, .confirmed, note: nil, at: t0.addingTimeInterval(120))
        let merged = mac.merged(with: phone, takeCoaching: false)
        XCTAssertEqual(merged.questions.first?.status, .confirmed)
        XCTAssertEqual(phone.merged(with: mac).questions.first?.status, .confirmed, "an older open copy does not undo the answer")
    }

    func testThePromptListsOpenAndDeniedQuestionsSoTheCoachDoesNotRepeatThem() {
        var p = CoachProfile()
        p.ask([question("Mitch reports to you."), question("Jo leads Finance.")])
        p.answer(p.questions[1].id, .rejected, note: nil, at: t0)
        let text = CoachPrompt.questionsText(p)
        XCTAssertTrue(text.contains("Waiting for an answer:\n- Mitch reports to you."), text)
        XCTAssertTrue(text.contains("Not true:\n- Jo leads Finance."), text)
    }

    func testTheReviewReturnsTheCoachsQuestionsForTheCall() async throws {
        let model = FakeModel(output: [
            "quiet": true, "headline": "H", "did_well": NSNull(), "improving": NSNull(), "try_next": NSNull(),
            "focus_result": NSNull(), "focus_proposal": NSNull(), "strengths": [], "improvements": [],
            "meeting_value": ["rating": "medium", "reason": "R", "action": "keep", "suggestion": ""],
            "profile": ["summary": "", "patterns": [], "people": []],
            "questions": [["statement": "Mitch reports to you.", "kind": "relationship", "evidence": "“Mitch, can you own this?”", "at_seconds": 75]],
        ])
        let coach = LLMCoach(llm: model, ownerName: "Dana")
        let r = CallRecord(id: "c9", platform: .meet, bundleID: "", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        let result = try await coach.review(record: r, profile: CoachProfile(), tone: nil)
        XCTAssertEqual(result.questions.map(\.statement), ["Mitch reports to you."])
        XCTAssertEqual(result.questions.first?.callID, "c9")
        XCTAssertEqual(result.questions.first?.at, 75)
        let schema = try XCTUnwrap(model.schema)
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["questions"])
    }
}

/// Returns one fixed JSON object for every request, and keeps the last schema it was given.
final class FakeModel: LanguageModel, @unchecked Sendable {
    let output: [String: Any]
    private(set) var schema: [String: Any]?
    private(set) var user = ""

    init(output: [String: Any]) { self.output = output }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        self.schema = schema
        self.user = user
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: output))
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
