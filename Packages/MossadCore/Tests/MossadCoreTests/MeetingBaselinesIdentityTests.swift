import XCTest
@testable import MossadCore

/// A person's history across meetings is found by the person's id: two saved people with one name have their own.
final class MeetingBaselinesIdentityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let owner = "Avery Webb"

    private func oneOnOne(_ id: String, daysAgo: Double, share: Double, person: String?) -> MeetingFacts {
        MeetingFacts(id: id, stamp: 0, start: start.addingTimeInterval(-daysAgo * 86_400), title: "Catch up \(id)", series: nil, kind: nil, tags: [], voices: 2,
                     people: [MeetingFacts.Person(name: owner, isOwner: true, values: [.talkShare: 1 - share]),
                              MeetingFacts.Person(name: "Sam Carter", personID: person, isOwner: false, values: [.talkShare: share])],
                     values: [:])
    }

    func testTwoPeopleWithOneNameHaveTheirOwnOneOnOnes() throws {
        let history = (0..<4).map { oneOnOne("a\($0)", daysAgo: Double($0 + 1), share: 0.2, person: "id-1") }
            + (0..<4).map { oneOnOne("b\($0)", daysAgo: Double($0 + 1), share: 0.8, person: "id-2") }
        let this = oneOnOne("now", daysAgo: 0, share: 0.25, person: "id-1")
        let past = MeetingAnalytics.History(this: this, history: history)
        let sam = try XCTUnwrap(this.partner)
        let (context, rows) = try XCTUnwrap(past.context(for: sam))
        XCTAssertEqual(context.kind, .oneOnOne)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.meeting.id)), ["a0", "a1", "a2", "a3"], "the other Sam Carter's meetings are not this one's history")
    }

    func testAMeetingFromBeforeIdsCountsByTheName() throws {
        let history = (0..<4).map { oneOnOne("a\($0)", daysAgo: Double($0 + 1), share: 0.2, person: nil) }
        let this = oneOnOne("now", daysAgo: 0, share: 0.25, person: "id-1")
        let (_, rows) = try XCTUnwrap(MeetingAnalytics.History(this: this, history: history).context(for: try XCTUnwrap(this.partner)))
        XCTAssertEqual(rows.count, 4)
    }

    func testTheFactsOfARecordCarryTheIdsOfItsVoices() {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(600), status: .written)
        r.speakerNames = ["me:A": owner, "them:A": "Sam Carter"]
        r.speakerPeople = ["them:A": "id-1"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 30, text: "Hello there."),
                        Utterance(track: .them, speakerLabel: "A", start: 31, end: 60, text: "Hello to you.")]
        let facts = MeetingFacts(record: r, owner: owner)
        XCTAssertEqual(facts.people.first { $0.name == "Sam Carter" }?.personID, "id-1")
        var other = r
        other.speakerPeople = ["them:A": "id-2"]
        XCTAssertNotEqual(MeetingAnalytics.stamp(r), MeetingAnalytics.stamp(other), "a new id is read again")
    }
}
