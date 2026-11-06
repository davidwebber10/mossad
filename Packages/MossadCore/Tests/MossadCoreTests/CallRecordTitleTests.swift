import XCTest
@testable import MossadCore

final class CallRecordTitleTests: XCTestCase {
    private func record() -> CallRecord {
        CallRecord(id: "a", platform: .meet, bundleID: "b", start: Date(), end: Date(), status: .written)
    }

    func testPrecedenceCustomCalendarGeneratedPlatform() {
        var r = record()
        XCTAssertEqual(r.title, "Google Meet call")
        XCTAssertEqual(r.titleSource, .platform)
        r.generatedTitle = "Freight review"
        XCTAssertEqual(r.title, "Freight review")
        XCTAssertEqual(r.titleSource, .generated)
        r.calendarTitle = "Weekly sync"
        XCTAssertEqual(r.title, "Weekly sync")
        XCTAssertEqual(r.titleSource, .calendar)
        r.customTitle = "Mine"
        XCTAssertEqual(r.title, "Mine")
        XCTAssertEqual(r.titleSource, .custom)
    }

    func testApplyingASummarySetsOnlyTheGeneratedTitle() {
        var r = record()
        r.customTitle = "Mine"
        r.calendarTitle = "Weekly sync"
        r.apply(MeetingSummary(summary: "s", actionItems: [], title: "Generated"))
        XCTAssertEqual(r.generatedTitle, "Generated")
        XCTAssertEqual(r.customTitle, "Mine")
        XCTAssertEqual(r.calendarTitle, "Weekly sync")
    }

    func testASummaryWithoutATitleKeepsTheGeneratedOne() {
        var r = record()
        r.generatedTitle = "Live guess"
        r.apply(MeetingSummary(summary: "s", actionItems: []))
        XCTAssertEqual(r.generatedTitle, "Live guess")
    }

    func testOldRecordDecodesWithBothNil() throws {
        let json = #"{"id":"a","platform":"meet","bundleID":"b","start":"2026-10-20T14:30:00Z","end":"2026-10-20T15:00:00Z","status":"written"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = try d.decode(CallRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.generatedTitle)
        XCTAssertNil(r.customTitle)
    }

    func testRoundTripKeepsBothTitles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = record()
        r.generatedTitle = "G"
        r.customTitle = "C"
        try r.save(to: dir)
        let back = try CallRecord.load(from: dir)
        XCTAssertEqual(back.generatedTitle, "G")
        XCTAssertEqual(back.customTitle, "C")
    }
}

final class LiveTitlerTests: XCTestCase {
    func testAsksOnceWithTheTranscriptAndCleansTheTitle() async {
        let model = FakeModel(output: ["title": "  \"Freight model review with Dana\".  "])
        let title = await LiveTitler(llm: model).title(transcript: "[00:01] Dana Lee: Let us review freight.")
        XCTAssertEqual(title, "Freight model review with Dana")
        XCTAssertTrue(model.user.contains("review freight"))
    }

    func testLongTitleIsCutAtSixtyCharacters() async {
        let model = FakeModel(output: ["title": String(repeating: "word ", count: 30)])
        let title = await LiveTitler(llm: model).title(transcript: "x")
        XCTAssertLessThanOrEqual(title?.count ?? 0, 60)
    }

    func testBlankTitleOrEmptyTranscriptGivesNil() async {
        let blank = FakeModel(output: ["title": "   "])
        let a = await LiveTitler(llm: blank).title(transcript: "hello")
        XCTAssertNil(a)
        let b = await LiveTitler(llm: FakeModel(output: ["title": "x"])).title(transcript: "  ")
        XCTAssertNil(b)
    }
}
