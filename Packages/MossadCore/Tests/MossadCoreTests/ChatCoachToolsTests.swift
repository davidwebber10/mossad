import XCTest
@testable import MossadCore

final class ChatCoachToolsTests: XCTestCase {
    private var paths: Paths!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        var r = CallRecord(id: "c1", platform: .meet, bundleID: "", start: base, end: base.addingTimeInterval(1800), status: .written)
        r.calendarTitle = "Mitch / David"
        r.speakerNames = ["me:A": "David Webber", "them:A": "Mitch Haus"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 120, text: "Let us start with the budget."),
                        Utterance(track: .them, speakerLabel: "A", start: 130, end: 400, text: "Sure.")]
        try FileManager.default.createDirectory(at: paths.callDirectory("c1"), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory("c1"))
        var review = CoachReview(headline: "Strong open, loose close", overview: "O",
                                 strengths: [CoachPoint(title: "Framed the goal", observation: "Opened with the budget.", quote: "Let us start", at: 0, principle: "BLUF", tryInstead: nil)],
                                 improvements: [CoachPoint(title: "Close the loop", observation: "No owner was named.", quote: "Sure", at: 130, principle: "Close the loop", tryInstead: "Who owns this, by when?")],
                                 focusProgress: nil,
                                 scorecard: Scorecard(score: 3, reason: "Clear open, loose close.", dimensions: [Scorecard.Dimension(name: "Clarity", score: 4)],
                                                      positives: ["Opened with the budget decision"], negatives: ["No owner for the next step"]))
        review.feedback["Close the loop"] = CoachFeedback(agree: false, note: "Mitch owns it by default.")
        try review.save(in: paths.callDirectory("c1"))
        var profile = CoachProfile()
        profile.focus = "Close every call with owners and dates."
        profile.updateFacts(add: [CoachFact(kind: .role, text: "Head of data and technology")], remove: [])
        profile.people["Mitch Haus"] = CoachPerson(note: "Direct report; wants the decision first.", calls: 3, lastSeen: base)
        try profile.save(to: paths.coach)
    }

    private var tools: ChatTools { ChatTools(records: ProcessingQueue(paths: paths).allRecords(), owner: "David Webber", paths: paths) }

    func testTheCoachProfileToolCarriesFocusAndFacts() {
        let text = tools.run("coach_profile", input: [:])
        XCTAssertTrue(text.contains("Close every call with owners and dates."), text)
        XCTAssertTrue(text.contains("Head of data and technology"))
    }

    func testCoachReviewsListScoresAndKeyPoints() {
        let text = tools.run("coach_reviews", input: [:])
        XCTAssertTrue(text.contains("call_id: c1"), text)
        XCTAssertTrue(text.contains("3/5"))
        XCTAssertTrue(text.contains("+ Opened with the budget decision"))
        XCTAssertTrue(text.contains("- No owner for the next step"))
    }

    func testReadingAReviewIncludesTheOwnersFeedback() {
        let text = tools.run("read_coach_review", input: ["call_id": "c1"])
        XCTAssertTrue(text.contains("Close the loop"), text)
        XCTAssertTrue(text.contains("Who owns this, by when?"))
        XCTAssertTrue(text.contains("Mitch owns it by default."))
    }

    func testPeopleCombineStatsAndCoachNotes() {
        let text = tools.run("people", input: ["query": "mitch"])
        XCTAssertTrue(text.contains("Mitch Haus"), text)
        XCTAssertTrue(text.contains("wants the decision first"))
    }

    func testStatsSummarizeAPeriod() {
        let text = tools.run("stats", input: ["from": "2027-01-01", "to": "2027-12-31"])
        XCTAssertTrue(text.contains("1 call"), text)
    }

    func testRememberWritesToTheCoachsMemory() throws {
        let reply = tools.run("remember", input: ["kind": "responsibility", "text": "Vendor contracts for data tools"])
        XCTAssertTrue(reply.lowercased().contains("remember"), reply)
        XCTAssertEqual(try CoachProfile.load(from: paths.coach).facts(.responsibility).map(\.text), ["Vendor contracts for data tools"])
        _ = tools.run("remember", input: ["kind": "preference", "text": "Skip filler-word advice."])
        XCTAssertEqual(try CoachProfile.load(from: paths.coach).guidance.map(\.text), ["Skip filler-word advice."])
    }

    func testPastChatsAreListedAndReadable() throws {
        var chat = Chat(title: "Budget prep")
        chat.summary = "Planned how to pitch two hires to Ben."
        chat.messages = [ChatMessage(role: .user, text: "How do I pitch two hires?"), ChatMessage(role: .assistant, text: "Lead with the cost of not hiring.")]
        try ChatStore(directory: paths.chats).save(chat)
        let list = tools.run("past_chats", input: [:])
        XCTAssertTrue(list.contains("Planned how to pitch two hires to Ben."), list)
        let full = tools.run("read_chat", input: ["chat_id": chat.id.uuidString])
        XCTAssertTrue(full.contains("Lead with the cost of not hiring."), full)
    }

    func testTheSystemPromptKnowsTheOwnerAndRecentChats() throws {
        var chat = Chat(title: "Budget prep")
        chat.summary = "Planned how to pitch two hires."
        try ChatStore(directory: paths.chats).save(chat)
        let system = ChatAgent.system(owner: "David Webber", tools: tools, now: base)
        XCTAssertTrue(system.contains("Close every call with owners and dates."), system)
        XCTAssertTrue(system.contains("Planned how to pitch two hires."))
        XCTAssertTrue(system.contains("remember"))
    }
}

extension ChatCoachToolsTests {
    func testLiveChatAnswersFromTheCoach() async throws {
        guard let key = APIKey.anthropic.value(in: ProcessInfo.processInfo.environment) else { throw XCTSkip("key not set") }
        let agent = ChatAgent(apiKey: key, ownerName: "David Webber")
        let records = ProcessingQueue(paths: paths).allRecords()
        let answer = try await agent.answer("from the coach, whats the #1 key point of feedback. 1 positive and 1 negative.", history: [],
                                            records: records, paths: paths) { print("LIVE step: \($0)") }
        print("LIVE coach chat: \(answer)")
        XCTAssertTrue(answer.lowercased().contains("budget") || answer.lowercased().contains("owner"))
        let remember = try await agent.answer("For future advice: I'm responsible for all vendor contracts for data tools.", history: [],
                                              records: records, paths: paths) { print("LIVE step: \($0)") }
        print("LIVE remember: \(remember)")
        XCTAssertFalse(try CoachProfile.load(from: paths.coach).facts(.responsibility).isEmpty)
    }
}
