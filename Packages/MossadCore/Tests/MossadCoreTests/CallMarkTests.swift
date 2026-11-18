import XCTest
@testable import MossadCore

final class CallMarkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    private func roundTrip(_ r: CallRecord) throws -> CallRecord {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CallMarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try r.save(to: dir)
        return try CallRecord.load(from: dir)
    }

    func testTheThreeFieldsAreSavedAndReadBack() throws {
        var r = CallRecord(id: "20261101-100000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 3600, status: .recorded)
        r.pauses = [PauseSpan(at: 600, from: t0 + 600, to: t0 + 900), PauseSpan(at: 1200, from: t0 + 1500, to: nil)]
        r.callMarks = [CallMark(at: 1800, time: t0 + 2100, link: "abc-defg-hij", platform: .meet, source: .tabs, sure: true),
                       CallMark(at: 2400, time: t0 + 2700, link: nil, platform: .meet, source: .title, sure: false,
                                titleKey: "2be7ef95b4132e1d")]
        r.cutFrom = "20261101-090000"
        r.firstTitleKey = "08786467415118f4"
        let back = try roundTrip(r)
        XCTAssertEqual(back.callMarks?.last?.titleKey, "2be7ef95b4132e1d")
        XCTAssertNil(back.callMarks?.first?.titleKey)
        XCTAssertEqual(back.firstTitleKey, "08786467415118f4")
        XCTAssertEqual(back.pauses, r.pauses)
        XCTAssertEqual(back.callMarks, r.callMarks)
        XCTAssertEqual(back.cutFrom, "20261101-090000")
        XCTAssertEqual(back, r)
    }

    func testARecordOfAnOlderBuildHasNoneOfThem() throws {
        let old = """
        {"id":"20261101-100000","platform":"meet","bundleID":"com.google.Chrome","start":"2026-11-01T10:00:00Z",
         "end":"2026-11-01T11:00:00Z","status":"written"}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = try d.decode(CallRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.pauses)
        XCTAssertNil(r.callMarks)
        XCTAssertNil(r.cutFrom)
        XCTAssertNil(r.firstTitleKey)
    }

    func testARecordWithoutThemWritesNoKey() throws {
        let r = CallRecord(id: "20261101-100000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 60, status: .recorded)
        let text = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        for key in ["pauses", "callMarks", "cutFrom", "firstTitleKey"] { XCTAssertFalse(text.contains("\"\(key)\""), key) }
    }

    func testTheSourcesKeepTheirTexts() throws {
        XCTAssertEqual(CallMark.Source.ext.rawValue, "extension")
        XCTAssertEqual(CallMark.Source.tabs.rawValue, "tabs")
        XCTAssertEqual(CallMark.Source.title.rawValue, "title")
        let mark = CallMark(at: 1, time: t0, link: nil, platform: .zoom, source: .ext, sure: true)
        let text = String(decoding: try JSONEncoder().encode(mark), as: UTF8.self)
        XCTAssertTrue(text.contains("\"extension\""), text)
        XCTAssertFalse(text.contains("titleKey"), "a mark with no title key writes no key")
        let old = #"{"at":1,"time":"2026-11-01T10:00:00Z","platform":"meet","source":"title","sure":false}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        XCTAssertNil(try d.decode(CallMark.self, from: Data(old.utf8)).titleKey)
    }
}
