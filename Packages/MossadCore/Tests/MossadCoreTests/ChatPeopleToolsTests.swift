import XCTest
@testable import MossadCore

/// `read_person` and `people`: one person in full on a sure match, with the facts of their page, and the read of how
/// they think only where the app shows it.
final class ChatPeopleToolsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var paths: Paths!

    private var owner: Person { Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: t0) }

    private var sam: Person {
        var p = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: t0)
        p.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: t0),
                    EmailIdentity(address: "old@example.com", state: .rejected, source: .owner, at: t0)]
        p.directory = DirectoryDetails(jobTitle: "Staff Engineer", department: "Platform", photoURL: URL(string: "https://example.com/p.jpg"),
                                       source: .googleDirectory, updated: t0)
        return p
    }

    private var dana: Person {
        var p = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", origin: .migration, at: t0)
        p.doNotProfile = true
        return p
    }

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
    }

    private func records() -> [CallRecord] {
        var a = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        a.calendarTitle = "Sam / Avery"
        a.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        a.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam"]
        a.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 60, text: "Shall we look at the budget?"),
                        Utterance(track: .them, speakerLabel: "A", start: 61, end: 300, text: "Yes, the budget is tight.")]
        a.actionItems = [ActionItem(owner: "Sam Carter", task: "Send the vendor list", ownerID: "id-sam")]
        a.tags = ["Budget"]
        var b = CallRecord(id: "b", platform: .zoom, bundleID: "b", start: t0.addingTimeInterval(-7 * 86_400), end: t0.addingTimeInterval(-7 * 86_400 + 1200), status: .written)
        b.calendarTitle = "Planning"
        b.speakerNames = ["me:A": "Avery Webb", "them:A": "Dana Lee"]
        b.attendees = ["Sam Carter", "Dana Lee"]
        b.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 100, text: "Plans.")]
        return [a, b]
    }

    private func tools(personas: Bool = true, people: [Person]? = nil) -> ChatTools {
        ChatTools(records: records(), owner: "Avery Webb", paths: paths, people: people ?? [owner, sam, dana], personaTraits: personas)
    }

    private func savePersonas() throws {
        func read(_ person: String, _ name: String) throws -> PersonaSummary {
            var p = Persona(person: person, updated: t0)
            let id = "\(person)|order|answer_first|any"
            p.evidence = [1, 4, 7, 10, 13, 16].map { PersonaTraitsTests.moment($0) }
            p.texts[id] = PersonaText(statement: "\(name) asks for the answer first.", soDoThis: "Open with the answer.", rating: .medium, written: t0, calls: 3, counter: 0)
            return try XCTUnwrap(PersonaSummary.make(p, answers: [], name: name))
        }
        let copy = SyncedPersonas([try read("id-sam", "Sam"), try read("id-dana", "Dana")])
        try JSONEncoder.callRecord.encode(copy).write(to: paths.coach.appendingPathComponent(SyncedPersonas.fileName))
    }

    func testReadPersonByIdNameOrAddressGivesTheBandAndTheirMeetings() throws {
        for query in ["id-sam", "Sam Carter", "sam@example.com"] {
            let text = tools().run("read_person", input: ["person": query])
            XCTAssertTrue(text.contains("person_id: id-sam | Sam Carter"), "\(query): \(text)")
        }
        let text = tools().run("read_person", input: ["person": "Sam Carter"])
        XCTAssertTrue(text.contains("Staff Engineer · Platform"), text)
        XCTAssertTrue(text.contains("sam@example.com"), text)
        XCTAssertFalse(text.contains("old@example.com"), "a rejected address is not theirs")
        XCTAssertFalse(text.contains("p.jpg"), "no photo link")
        // The band, by the rule of the person page: one meeting together, one where they were only invited.
        XCTAssertTrue(text.contains("2 meetings · 1 only invited"), text)
        XCTAssertTrue(text.contains("call_id: a"), text)
        XCTAssertTrue(text.contains("call_id: b") && text.contains("only invited"), text)
        XCTAssertTrue(text.contains("Send the vendor list"), "their action items")
        XCTAssertTrue(text.contains("Budget"), "the topics together")
    }

    func testReadPersonNeedsASureMatch() {
        XCTAssertTrue(tools().run("read_person", input: ["person": "Sa"]).hasPrefix("No saved person is surely"))
        XCTAssertTrue(tools().run("read_person", input: [:]).hasPrefix("No saved person is surely"))
    }

    func testTheReadOfHowTheyThinkFollowsTheSwitchAndNeverShowsADoNotProfilePerson() throws {
        try savePersonas()
        XCTAssertTrue(tools().run("read_person", input: ["person": "id-sam"]).contains("asks for the answer first"))
        XCTAssertFalse(tools(personas: false).run("read_person", input: ["person": "id-sam"]).contains("asks for the answer first"), "the switch for other AI apps")
        let dana = tools().run("read_person", input: ["person": "id-dana"])
        XCTAssertTrue(dana.contains("person_id: id-dana"), dana)
        XCTAssertFalse(dana.contains("asks for the answer first"), "a person with no read kept")
        XCTAssertFalse(tools().run("people", input: ["query": "Dana"]).contains("asks for the answer first"))
    }

    func testReadPersonShowsTheirNextTimePointsAndYourPromises() throws {
        var book = NextTimeBook()
        _ = book.add("Ask about the hiring plan", personID: "id-sam", personName: "Sam Carter", at: t0)
        try book.save(to: paths.nextTime)
        var c = CommitmentBook()
        var promise = Commitment(text: "Share the forecast", to: "Sam Carter", callID: "a", callTitle: "Sam / Avery", madeAt: t0, due: nil)
        promise.toID = "id-sam"
        c.items = [promise]
        try c.save(to: paths.commitments)
        let text = tools().run("read_person", input: ["person": "Sam"])
        XCTAssertTrue(text.contains("No saved person is surely"), "a first name alone is no sure match: \(text)")
        let full = tools().run("read_person", input: ["person": "Sam Carter"])
        XCTAssertTrue(full.contains("Ask about the hiring plan"), full)
        XCTAssertTrue(full.contains("Share the forecast"), full)
    }

    func testSectionsLimitTheAnswer() {
        let text = tools().run("read_person", input: ["person": "id-sam", "sections": ["meetings"]])
        XCTAssertTrue(text.contains("call_id: a"), text)
        XCTAssertFalse(text.contains("Send the vendor list"), text)
    }

    func testTheVoiceSectionGivesCountsNeverFingerprints() {
        let profiles = [VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [[0.123456, 0.5], [0.25, 0.75]])]
        let tools = ChatTools(records: records(), owner: "Avery Webb", paths: paths, people: [owner, sam, dana], profiles: profiles)
        let text = tools.run("read_person", input: ["person": "id-sam", "sections": ["voice"]])
        XCTAssertTrue(text.contains("2 voice samples"), text)
        XCTAssertFalse(text.contains("0.123"), "no numbers of a fingerprint")
    }

    func testPeopleNameEachPersonsIdAndJob() {
        let text = tools().run("people", input: [:])
        XCTAssertTrue(text.contains("Sam Carter | person_id: id-sam | Staff Engineer"), text)
    }

    func testPeopleListPossibleDuplicatesAndNeverMergeThem() {
        let profiles = [VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [], email: "sam@example.com"),
                        VoiceProfile(name: "Samuel Carter", isOwner: false, embeddings: [], email: "sam@example.com")]
        let tools = ChatTools(records: records(), owner: "Avery Webb", paths: paths, people: [owner, sam, dana], profiles: profiles)
        let text = tools.run("people", input: ["duplicates": true])
        XCTAssertTrue(text.contains("Sam Carter and Samuel Carter"), text)
        XCTAssertTrue(text.contains("same email"), text)
    }
}
