import XCTest
@testable import MossadCore

/// The chat and MCP tools name each saved person's id, take an id or any name of the person, and so find a
/// person after a rename by the old name too.
final class ChatToolsIdentityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func setUp(renamed: Bool) -> ChatTools {
        var sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: t0)
        let owner = Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: t0)
        if renamed { sam.rename(to: "Sam Brooks", source: .owner, at: t0) }
        var a = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        a.speakerNames = ["me:A": "Avery Webb", "them:A": renamed ? "Sam Brooks" : "Sam Carter"]
        a.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam"]
        a.actionItems = [ActionItem(owner: "Sam", task: "send it", ownerID: "id-sam")]
        var b = CallRecord(id: "b", platform: .meet, bundleID: "b", start: t0.addingTimeInterval(-86_400), end: t0, status: .written)
        b.speakerNames = ["me:A": "Avery Webb", "them:A": "Dana Lee"]
        return ChatTools(records: [a, b], owner: "Avery Webb", people: [owner, sam])
    }

    func testTheOldNameAndTheIdFindThePersonAfterARename() {
        let tools = setUp(renamed: true)
        XCTAssertEqual(tools.findMeetings(people: ["Sam Carter"]).map(\.id), ["a"], "the name of before")
        XCTAssertEqual(tools.findMeetings(people: ["id-sam"]).map(\.id), ["a"])
        XCTAssertEqual(tools.findMeetings(people: ["Sam Brooks"]).map(\.id), ["a"])
        XCTAssertEqual(tools.findMeetings(people: ["Dana"]).map(\.id), ["b"], "a first name as before")
        XCTAssertEqual(tools.actionItems(owner: "Sam Carter").map(\.task), ["send it"])
    }

    func testReadMeetingNamesTheIds() throws {
        let text = try XCTUnwrap(setUp(renamed: false).readMeeting("a"))
        XCTAssertTrue(text.contains("person_ids: Avery Webb=id-owner; Sam Carter=id-sam"), text)
        XCTAssertFalse(try XCTUnwrap(setUp(renamed: false).readMeeting("b")).contains("person_ids"))
    }

    func testWithNoPeopleNamesMatchAsText() {
        var a = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0, status: .written)
        a.speakerNames = ["them:A": "Sam Brooks"]
        a.speakerPeople = ["them:A": "id-sam"]
        XCTAssertTrue(ChatTools(records: [a], owner: "Avery Webb", people: []).findMeetings(people: ["Sam Carter"]).isEmpty)
    }
}

extension ChatToolsIdentityTests {
    func testSearchFindsAPersonByANameOfBefore() {
        var sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: t0)
        sam.rename(to: "Sam Brooks", source: .owner, at: t0)
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.speakerNames = ["them:A": "Sam Brooks"]
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 2, text: "Hello.")]
        var index = SearchIndex(records: [r], people: [VoiceProfile(name: "Sam Brooks", isOwner: false, embeddings: [])])
        func people(_ q: String) -> [String] {
            let r = index.search(q, now: t0)
            if case .person(let p) = r.topHit { return [p.name.text] + r.people.map(\.name.text) }
            return r.people.map(\.name.text)
        }
        XCTAssertTrue(people("Carter").isEmpty)
        index.setOtherNames([sam])
        XCTAssertEqual(people("Sam Carter"), ["Sam Brooks"])
        XCTAssertEqual(people("Brooks"), ["Sam Brooks"])
    }
}
