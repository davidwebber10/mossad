import XCTest
@testable import MossadCore

final class MeetingQATests: XCTestCase {
    private func call(_ id: String, day: Double, title: String, lines: [String], summary: String? = nil, tags: [String] = []) -> CallRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = title
        r.summary = summary
        r.tags = tags
        r.speakerNames = ["me:A": "David Webber", "them:A": "Mitch Haus"]
        r.utterances = lines.enumerated().map { i, text in
            Utterance(track: i % 2 == 0 ? .me : .them, speakerLabel: "A", start: Double(i * 30), end: Double(i * 30 + 20), text: text)
        }
        return r
    }

    func testRanksMeetingsByTheQuestionsWordsAndIgnoresCommonWords() {
        let records = [
            call("a", day: 1, title: "Ops sync", lines: ["We talked about freight.", "Freight rates went up."]),
            call("b", day: 2, title: "Data", lines: ["The Supermetrics renewal is in December.", "We should decide on Supermetrics soon."],
                 tags: ["Supermetrics"]),
            call("c", day: 3, title: "Budget", lines: ["What is the plan for the budget?"]),
        ]
        let picked = MeetingQA.relevant(records, question: "What did we decide about the Supermetrics renewal?")
        XCTAssertEqual(picked.first?.id, "b")
        XCTAssertFalse(picked.contains { $0.id == "a" })
    }

    func testAGeneralQuestionFallsBackToTheLatestMeetings() {
        let records = (0..<30).map { call("m\($0)", day: Double($0), title: "Call \($0)", lines: ["Hello."]) }
        let picked = MeetingQA.relevant(records, question: "What happened recently?")
        XCTAssertEqual(picked.count, MeetingQA.fallbackCount)
        XCTAssertEqual(picked.first?.id, "m29")
    }

    func testMaterialHasIDsSummariesAndExcerptsWithTimes() {
        let r = call("b", day: 2, title: "Data sync", lines: ["Intro.", "Other thing.", "Supermetrics renewal is in December.", "OK."],
                     summary: "Talked about vendors.")
        let text = MeetingQA.material([r], question: "supermetrics renewal")
        XCTAssertTrue(text.contains("call_id: b"), text)
        XCTAssertTrue(text.contains("Data sync"))
        XCTAssertTrue(text.contains("Talked about vendors."))
        XCTAssertTrue(text.contains("[00:01:00] David Webber: Supermetrics renewal is in December."), text)
        // One line of context on each side.
        XCTAssertTrue(text.contains("Other thing."))
    }

    func testParsesTheAnswerAndCitations() async throws {
        let output = #"{"answer":"You agreed Mitch decides by Friday.","citations":[{"call_id":"b","at_seconds":60,"quote":"Supermetrics renewal"},{"call_id":"zzz","at_seconds":null,"quote":"x"}]}"#
        StubURLProtocol.handler = { _ in (200, json(["stop_reason": "end_turn", "content": [["type": "text", "text": output]]])) }
        let qa = MeetingQA(apiKey: "k", session: StubURLProtocol.session(), ownerName: "David Webber")
        let records = [call("b", day: 2, title: "Data", lines: ["Supermetrics renewal."])]
        let answer = try await qa.ask("Supermetrics?", records: records)
        XCTAssertEqual(answer.text, "You agreed Mitch decides by Friday.")
        // A citation to a meeting that was not given is dropped.
        XCTAssertEqual(answer.citations, [MeetingQA.Citation(callID: "b", at: 60, quote: "Supermetrics renewal")])
    }

    // MARK: People, dates, and follow-ups

    private func meeting(_ id: String, day: Double, people: [String], lines: [String] = ["Let us get going.", "Sounds good."]) -> CallRecord {
        var r = call(id, day: day, title: "Call \(id)", lines: lines)
        r.speakerNames = ["me:A": "David Webber"]
        for (i, p) in people.enumerated() { r.speakerNames["them:\(Character(UnicodeScalar(UInt8(65 + i))))"] = p }
        return r
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 10 * 86_400)

    func testFindsThePeopleNamedEvenByAShortFirstName() {
        let records = [meeting("a", day: 1, people: ["Jennifer Lee", "Austin Ray"]), meeting("d", day: 2, people: ["Mitch Haus"])]
        XCTAssertEqual(MeetingQA.people(in: "what did Jen and Austin agree to", records: records), ["Jennifer Lee", "Austin Ray"])
        XCTAssertEqual(MeetingQA.people(in: "anything from mitch?", records: records), ["Mitch Haus"])
        XCTAssertEqual(MeetingQA.people(in: "what is the plan", records: records), [])
    }

    func testPrefersTheLatestMeetingWithEveryoneNamed() {
        let records = [
            meeting("old", day: 1, people: ["Jennifer Lee", "Austin Ray"]),
            meeting("both", day: 5, people: ["Jennifer Lee", "Austin Ray", "Mitch Haus"]),
            meeting("austin", day: 8, people: ["Austin Ray"]),
            meeting("mitch", day: 9, people: ["Mitch Haus"]),
        ]
        let picked = MeetingQA.relevant(records, question: "What did Jen and Austin agree to do last call, and was there a deadline?", now: now)
        XCTAssertEqual(picked.map(\.id).prefix(2), ["both", "old"])
        XCTAssertFalse(picked.contains { $0.id == "mitch" })
    }

    func testDateWordsNarrowThePeriod() {
        let records = [meeting("recent", day: 9, people: ["Mitch Haus"]), meeting("older", day: 2, people: ["Mitch Haus"])]
        XCTAssertEqual(MeetingQA.relevant(records, question: "What did Mitch say yesterday?", now: now).map(\.id), ["recent"])
        XCTAssertEqual(MeetingQA.relevant(records, question: "What did Mitch say?", now: now).map(\.id), ["recent", "older"])
    }

    func testTheTopMeetingsGoInWhole() {
        let lines = (0..<50).map { "Line number \($0) about nothing in particular." }
        let r = meeting("both", day: 5, people: ["Austin Ray"], lines: lines)
        let text = MeetingQA.material([r], question: "what did austin agree to")
        XCTAssertTrue(text.contains("Line number 0 "))
        XCTAssertTrue(text.contains("Line number 49 "))
        XCTAssertTrue(text.contains("Full transcript"))
    }

    func testAFollowUpKeepsThePeopleFromEarlierInTheChat() {
        let records = [meeting("both", day: 5, people: ["Jennifer Lee", "Austin Ray"]), meeting("mitch", day: 9, people: ["Mitch Haus"])]
        let history = [MeetingQA.Turn(question: "What did Jen and Austin agree to last call?", answer: "To send the plan.")]
        let picked = MeetingQA.relevant(records, question: "Was there a deadline?", history: history, now: now)
        XCTAssertEqual(picked.first?.id, "both")
    }
}
