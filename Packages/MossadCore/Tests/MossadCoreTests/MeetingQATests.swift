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
}
