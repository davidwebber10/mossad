import XCTest
@testable import MossadCore

final class ActionItemTests: XCTestCase {
    func testTextJoinsOwnerAndTask() {
        XCTAssertEqual(ActionItem(owner: "Alex Rivera", task: "confirm freight").text, "Alex Rivera: confirm freight")
        XCTAssertEqual(ActionItem(owner: nil, task: "confirm freight").text, "confirm freight")
    }

    func testParsesOwnerOfOneToThreeWords() {
        XCTAssertEqual(ActionItem(parsing: "Alex Rivera: confirm freight"), ActionItem(owner: "Alex Rivera", task: "confirm freight"))
        XCTAssertEqual(ActionItem(parsing: "Unassigned: book a room"), ActionItem(owner: "Unassigned", task: "book a room"))
        XCTAssertEqual(ActionItem(parsing: "Mary Ann Lee: send it: today"), ActionItem(owner: "Mary Ann Lee", task: "send it: today"))
    }

    func testNoOwnerWhenPrefixIsLongOrMissing() {
        XCTAssertEqual(ActionItem(parsing: "Ask the whole team: who owns freight"),
                       ActionItem(owner: nil, task: "Ask the whole team: who owns freight"))
        XCTAssertEqual(ActionItem(parsing: "Book freight"), ActionItem(owner: nil, task: "Book freight"))
        XCTAssertEqual(ActionItem(parsing: ": empty owner"), ActionItem(owner: nil, task: ": empty owner"))
    }

    func record() -> CallRecord {
        CallRecord(id: "x", platform: .zoom, bundleID: "us.zoom.xos", start: Date(timeIntervalSince1970: 0),
                   end: Date(timeIntervalSince1970: 60), status: .written)
    }

    func testOldRecordDecodesStringActionItemsAndDefaults() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try record().save(to: dir)
        let url = dir.appendingPathComponent("call.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["actionItems"] = ["Alex Rivera: confirm freight", "Book freight"]
        json.removeValue(forKey: "decisions")
        json.removeValue(forKey: "headline")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try CallRecord.load(from: dir)
        XCTAssertEqual(loaded.actionItems, [ActionItem(owner: "Alex Rivera", task: "confirm freight"), ActionItem(owner: nil, task: "Book freight")])
        XCTAssertEqual(loaded.decisions, [])
        XCTAssertNil(loaded.headline)
    }

    func testNewRecordRoundTrips() throws {
        var r = record()
        r.actionItems = [ActionItem(owner: "Alex", task: "a"), ActionItem(owner: nil, task: "b")]
        r.decisions = ["Ship Friday"]
        r.headline = "Cushions ship Friday."
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try r.save(to: dir)
        XCTAssertEqual(try CallRecord.load(from: dir), r)
    }
}
