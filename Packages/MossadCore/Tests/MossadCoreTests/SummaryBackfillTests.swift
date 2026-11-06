import XCTest
@testable import MossadCore

final class SummaryBackfillTests: XCTestCase {
    private func record(_ id: String, day: Int, title: String? = nil, decisions: [Decision] = [], status: CallStatus = .written, talk: Bool = true, version: Int? = nil) -> CallRecord {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "x", start: start, end: start.addingTimeInterval(600), status: status)
        if talk { r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 5, text: "Hello")] }
        r.generatedTitle = title
        r.summaryVersion = version
        r.decisions = decisions
        return r
    }

    func testDueMeansWrittenWithTalkAndAnOlderSummary() {
        let all = [
            record("old", day: 1),
            record("titled-old", day: 2, title: "Plan", decisions: [Decision(text: "Ship", at: 30)]),
            record("current", day: 3, title: "Plan", decisions: [Decision(text: "Ship", at: nil)], version: SummaryBackfill.currentVersion),
            record("silent", day: 5, talk: false),
            record("pending", day: 6, status: .identified),
        ]
        XCTAssertEqual(SummaryBackfill.due(all).map(\.id), ["titled-old", "old"], "newest first; a current summary is never due")
    }

    func testApplyMarksTheSummaryCurrent() {
        var r = record("a", day: 1)
        r.apply(MeetingSummary(summary: "S", actionItems: [], decisions: [], headline: "H"))
        XCTAssertEqual(r.summaryVersion, SummaryBackfill.currentVersion)
    }

    func testOwnerTagsSurviveANewSummary() {
        var r = record("a", day: 1)
        r.tags = ["Mine"]
        r.tagsSetByOwner = true
        r.apply(MeetingSummary(summary: "S", actionItems: [], decisions: [], headline: "H", tags: ["Other"], title: "T"))
        XCTAssertEqual(r.tags, ["Mine"])
        XCTAssertEqual(r.generatedTitle, "T")
        var plain = record("b", day: 1)
        plain.apply(MeetingSummary(summary: "S", actionItems: [], decisions: [], headline: "H", tags: ["Other"]))
        XCTAssertEqual(plain.tags, ["Other"])
    }

    func testOldRecordsDecodeWithoutTheFlag() throws {
        let data = try JSONEncoder().encode(record("a", day: 1))
        XCTAssertNil(try JSONDecoder().decode(CallRecord.self, from: data).tagsSetByOwner)
    }
}
