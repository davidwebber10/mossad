import XCTest
@testable import MossadCore

/// The design's check of phase 2: rename a person with a brief, a commitment, and an org match. One write to the
/// people file is the rename; the brief, the commitment, and the org match stay with the person, and each record
/// gets the name of now from the one refresh step.
final class RenameEverywhereTests: XCTestCase {
    var paths: Paths!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testABriefACommitmentAndAnOrgMatchStayThroughARename() throws {
        let store = PeopleStore(directory: paths.people, now: { [t0] in t0 })
        let sam = try store.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        _ = try store.ensure(voiceName: "Avery Webb", isOwner: true, origin: .voiceNaming)
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.actionItems = [ActionItem(owner: "Sam Carter", task: "send it")]
        r = PersonReferences(people: store.people).refresh(r)
        var book = CommitmentBook()
        book.items = [Commitment(text: "Call back", to: "Sam Carter", callID: "a", callTitle: nil, madeAt: t0, due: nil, created: t0)]
        book = PersonReferences(people: store.people).refresh(book, records: [r])
        var org = OrgMatches()
        org.set("Sam Carter", to: "carter, sam")
        try org.save(paths: paths)
        var coach = CoachProfile()
        var note = CoachPerson(note: "Likes numbers first.", calls: 3, lastSeen: t0)
        note.brief = PersonBrief(headline: "Direct", sections: [], calls: 3, updated: t0)
        coach.people["Sam Carter"] = note
        coach.linkPeople(CoachPeople(people: store.people), records: [r])
        XCTAssertEqual(coach.people["Sam Carter"]?.person, sam.rawValue)

        // The rename: one write.
        let before = try Data(contentsOf: paths.people.appendingPathComponent(PeopleStore.fileName))
        try store.rename(sam, to: "Sam Brooks")
        XCTAssertNotEqual(try Data(contentsOf: paths.people.appendingPathComponent(PeopleStore.fileName)), before)

        // What holds the id needs no write to stay right.
        XCTAssertEqual(OrgMatches.load(paths: paths).personID(for: "Sam Brooks"), "carter, sam")
        let people = store.people
        XCTAssertEqual(PersonReferences(people: people).name(of: try XCTUnwrap(book.items[0].toID)), "Sam Brooks")
        XCTAssertEqual(coach.note(on: "Sam Brooks", people: CoachPeople(people: people))?.value.brief?.headline, "Direct")

        // The labels follow from the refresh.
        let refreshed = PersonReferences(people: people).refresh(r)
        XCTAssertEqual(refreshed.speakerNames["them:A"], "Sam Brooks")
        XCTAssertEqual(refreshed.actionItems[0].owner, "Sam Brooks")
        XCTAssertEqual(PersonReferences(people: people).refresh(book, records: [refreshed]).items[0].to, "Sam Brooks")
        coach.linkPeople(CoachPeople(people: people), records: [refreshed])
        XCTAssertEqual(coach.people["Sam Brooks"]?.brief?.headline, "Direct")
        XCTAssertNil(coach.people["Sam Carter"])
    }
}
