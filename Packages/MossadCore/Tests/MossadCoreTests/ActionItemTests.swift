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

    func testOldStringDecisionsDecodeWithoutATime() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try record().save(to: dir)
        let url = dir.appendingPathComponent("call.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["decisions"] = ["Ship Friday", ["text": "Hire two", "at": 61.5]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try CallRecord.load(from: dir).decisions, [Decision(text: "Ship Friday", at: nil), Decision(text: "Hire two", at: 61.5)])
    }

    func testEncodedDecisionsStayPlainStringsForOlderBuilds() throws {
        var r = record()
        r.decisions = [Decision(text: "Ship Friday", at: 3128), Decision(text: "Hire two", at: nil)]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(json["decisions"] as? [String], ["Ship Friday", "Hire two"])
        XCTAssertEqual((json["decisionTimes"] as? [Any])?.count, 2)
        r.decisions = [Decision(text: "No times", at: nil)]
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(plain["decisions"] as? [String], ["No times"])
        XCTAssertNil(plain["decisionTimes"])
    }

    func testStringDecisionsWithSeparateTimesDecode() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try record().save(to: dir)
        let url = dir.appendingPathComponent("call.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["decisions"] = ["Ship Friday", "Hire two"]
        json["decisionTimes"] = [NSNull(), 61.5]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try CallRecord.load(from: dir).decisions, [Decision(text: "Ship Friday", at: nil), Decision(text: "Hire two", at: 61.5)])
    }

    func testSummaryTimePastTheEndOfTheCallIsDropped() {
        var r = record()
        r.apply(MeetingSummary(summary: "S", actionItems: [], decisions: [Decision(text: "In", at: 59), Decision(text: "Out", at: 61)]))
        XCTAssertEqual(r.decisions, [Decision(text: "In", at: 59), Decision(text: "Out", at: nil)])
    }

    func testSharedMeetingKeepsDecisionsAsStringsWithTimes() throws {
        var r = record()
        r.decisions = [Decision(text: "Ship Friday", at: 30)]
        let view = MeetingView(r)
        let shared = SharedMeeting(view, owner: "Dana", options: ShareOptions(summary: true, transcript: false, recording: false, chat: false), expires: nil, model: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as! [String: Any]
        XCTAssertEqual(json["decisions"] as? [String], ["Ship Friday"])
        XCTAssertEqual(json["decisionTimes"] as? [Double], [30])
    }

    func testNewRecordRoundTrips() throws {
        var r = record()
        r.actionItems = [ActionItem(owner: "Alex", task: "a"), ActionItem(owner: nil, task: "b")]
        r.decisions = [Decision(text: "Ship Friday", at: 3128), Decision(text: "Hire two", at: nil)]
        r.headline = "Cushions ship Friday."
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try r.save(to: dir)
        XCTAssertEqual(try CallRecord.load(from: dir), r)
    }
}
