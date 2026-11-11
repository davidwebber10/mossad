import XCTest
@testable import MossadCore

/// The id fields are additive: an old file reads in this build, and a new file reads in a frozen copy of the
/// types as the builds before ids had them (the iPhone and an older Mac).
final class ReferenceCodableTests: XCTestCase {
    // The shapes before ids, frozen.
    private struct OldActionItem: Codable, Equatable { var owner: String?; var task: String }
    private struct OldInvitee: Codable, Equatable { var name: String?; var email: String?; var isSelf: Bool? }
    private struct OldCommitment: Codable {
        var id: UUID; var text: String; var to: String?; var callID: String?; var callTitle: String?; var madeAt: Date
        var at: TimeInterval?; var quote: String?; var due: Date?; var done: Date?; var deleted: Bool; var created: Date; var updated: Date
    }
    private struct OldRecordPart: Codable {
        var id: String; var speakerNames: [String: String]; var invitees: [OldInvitee]?; var actionItems: [OldActionItem]
    }

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func newRecord() -> CallRecord {
        var r = CallRecord(id: "20261105-100000", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(60), status: .written)
        r.speakerNames = ["them:A": "Sam Carter"]
        r.speakerPeople = ["them:A": "id-sam"]
        r.invitees = [Invitee(name: "Carter, Sam", email: "sam@example.com", personID: "id-sam")]
        r.actionItems = [ActionItem(owner: "Sam", task: "send it", ownerID: "id-sam")]
        return r
    }

    func testANewRecordReadsBackWithItsIds() throws {
        let data = try JSONEncoder.callRecord.encode(newRecord())
        XCTAssertEqual(try JSONDecoder.callRecord.decode(CallRecord.self, from: data), newRecord())
    }

    func testANewRecordReadsInTheOldShape() throws {
        let data = try JSONEncoder.callRecord.encode(newRecord())
        let old = try JSONDecoder.callRecord.decode(OldRecordPart.self, from: data)
        XCTAssertEqual(old.speakerNames, ["them:A": "Sam Carter"])
        XCTAssertEqual(old.invitees, [OldInvitee(name: "Carter, Sam", email: "sam@example.com", isSelf: nil)])
        XCTAssertEqual(old.actionItems, [OldActionItem(owner: "Sam", task: "send it")])
    }

    func testAnOldRecordReadsWithNoIds() throws {
        var r = PersonReferences.withoutIDs(newRecord())
        r.speakerPeople = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.callRecord.encode(r)) as? [String: Any])
        XCTAssertNil(json["speakerPeople"], "a record with no ids writes no key")
        json["actionItems"] = ["Sam: send it"]
        let back = try JSONDecoder.callRecord.decode(CallRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.speakerPeople)
        XCTAssertNil(back.invitees?.first?.personID)
        XCTAssertEqual(back.actionItems, [ActionItem(owner: "Sam", task: "send it")])
    }

    func testAnItemWithNoIdWritesTheSameBytesAsBefore() throws {
        let item = ActionItem(owner: "Sam", task: "send it")
        XCTAssertEqual(String(decoding: try JSONEncoder.callRecord.encode(item), as: UTF8.self), #"{"owner":"Sam","task":"send it"}"#)
    }

    func testACommitmentReadsInBothDirections() throws {
        var c = Commitment(text: "Send it", to: "Sam", callID: "c", callTitle: "T", madeAt: t0, due: nil, created: t0)
        c.toID = "id-sam"
        let data = try JSONEncoder.callRecord.encode(c)
        XCTAssertEqual(try JSONDecoder.callRecord.decode(Commitment.self, from: data).toID, "id-sam")
        let old = try JSONDecoder.callRecord.decode(OldCommitment.self, from: data)
        XCTAssertEqual(old.to, "Sam")
        let back = try JSONDecoder.callRecord.decode(Commitment.self, from: JSONEncoder.callRecord.encode(old))
        XCTAssertNil(back.toID)
        XCTAssertEqual(back.to, "Sam")
    }

    func testTheNoteIsTheSameWithIds() {
        var r = newRecord()
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 2, text: "Hello.")]
        r.summary = "Short."
        XCTAssertEqual(MarkdownWriter.render(r), MarkdownWriter.render(PersonReferences.withoutIDs(r)))
    }
}
