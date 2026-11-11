import XCTest
@testable import MossadCore

/// A person's page by the person's id: two people with one first name do not share commitments, and two saved
/// people with one name have their own meetings.
final class PersonRelationIdentityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func call(_ id: String, _ name: String, person: String?, item: ActionItem? = nil) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": "Avery Webb", "them:A": name]
        r.speakerPeople = person.map { ["them:A": $0] }
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 5, text: "Hi."), Utterance(track: .them, speakerLabel: "A", start: 6, end: 9, text: "Hi.")]
        r.actionItems = item.map { [$0] } ?? []
        return r
    }

    func testTwoPeopleWithOneFirstNameDoNotShareCommitments() {
        var toSam = Commitment(text: "Send it", to: "Sam", callID: "a", callTitle: nil, madeAt: t0, due: nil)
        toSam.toID = "id-sam"
        var toSamuel = Commitment(text: "Call", to: "Sam", callID: "b", callTitle: nil, madeAt: t0, due: nil)
        toSamuel.toID = "id-samuel"
        let unknown = Commitment(text: "Ask", to: "Sam", callID: nil, callTitle: nil, madeAt: t0, due: nil)
        let all = [toSam, toSamuel, unknown]
        let byID = PersonRelation(name: "Sam Carter", personID: "id-sam", owner: "Avery Webb", records: [], commitments: all)
        XCTAssertEqual(byID.myCommitments.map(\.text), ["Send it"], "a first name with no id is nobody's for sure")
        let byName = PersonRelation(name: "Sam Carter", owner: "Avery Webb", records: [], commitments: all)
        XCTAssertEqual(byName.myCommitments.count, 3, "with no id, as before")
    }

    func testTwoSavedPeopleWithOneNameHaveTheirOwnMeetingsAndItems() {
        let records = [call("a", "Sam Carter", person: "id-1", item: ActionItem(owner: "Sam Carter", task: "one", ownerID: "id-1")),
                       call("b", "Sam Carter", person: "id-2", item: ActionItem(owner: "Sam Carter", task: "two", ownerID: "id-2")),
                       call("c", "Sam Carter", person: nil)]
        let first = PersonRelation(name: "Sam Carter", personID: "id-1", owner: "Avery Webb", records: records)
        XCTAssertEqual(first.calls, 1, "an id says which Sam Carter; a record with no id and two saved people of the name is nobody's")
        XCTAssertEqual(first.theirItems.map(\.task), ["one"])
    }

    func testARecordFromBeforeIdsCountsByTheName() {
        let records = [call("a", "Sam Carter", person: "id-1"), call("c", "Sam Carter", person: nil)]
        XCTAssertEqual(PersonRelation(name: "Sam Carter", personID: "id-1", owner: "Avery Webb", records: records, nameIsUnique: true).calls, 2)
    }
}
