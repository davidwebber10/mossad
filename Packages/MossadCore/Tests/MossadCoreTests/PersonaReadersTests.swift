import XCTest
@testable import MossadCore

/// Where the reads show: Chat and other AI apps, the upcoming meeting's page, and the per-person switch.
final class PersonaReadersTests: XCTestCase {
    private let t0 = PersonaTraitsTests.t0
    private var root: URL!
    private var paths: Paths { Paths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("persona-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func person(_ name: String, owner: Bool = false) -> Person { Person(displayName: name, isOwner: owner, origin: .voiceNaming, at: t0) }

    /// A person with two shown traits (a card) and one with one shown trait (no card).
    private func persona(_ id: String, card: Bool) -> Persona {
        var p = Persona(person: id, updated: t0)
        p.evidence = [1, 4, 7].map { PersonaTraitsTests.moment($0) }
        p.texts["\(id)|order|answer_first|any"] = PersonaText(statement: "Sam asks for the answer first.", soDoThis: "Open with the answer.", rating: .medium,
                                                               written: t0, calls: 3, counter: 0)
        if card {
            p.evidence += [1, 4, 7].map { PersonaTraitsTests.moment($0, "evidence", "comparison") }
            p.texts["\(id)|evidence|comparison|any"] = PersonaText(statement: "Sam asks what a figure compares with.", soDoThis: "Bring a comparison.",
                                                                   rating: .medium, written: t0, calls: 3, counter: 0)
        }
        return p
    }

    private func meeting(_ id: String, with name: String) throws {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": "Dana Lee", "them:A": name]
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 5, text: "Hello there.")]
        try FileManager.default.createDirectory(at: paths.callDirectory(id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(id))
    }

    func testThePeopleToolGivesTheShownTraitsWithCountsAndTheOldReadUntilACard() throws {
        let sam = person("Sam Carter"), riley = person("Riley Chen")
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        try PeopleStore(directory: paths.people).replaceAll([person("Dana Lee", owner: true), sam, riley])
        try PersonaStore(paths: paths).save(persona(sam.id.rawValue, card: true))
        try PersonaStore(paths: paths).save(persona(riley.id.rawValue, card: false))
        var profile = CoachProfile()
        var note = CoachPerson(note: "", calls: 2, lastSeen: t0)
        note.brief = PersonBrief(headline: "Lead with the number.", sections: [], calls: 2, updated: t0)
        profile.people = ["Sam Carter": note, "Riley Chen": note]
        try profile.save(to: paths.coach)
        try meeting("c1", with: "Sam Carter")
        try meeting("c2", with: "Riley Chen")
        let tools = ChatTools(records: ProcessingQueue(paths: paths).allRecords(), owner: "Dana Lee", paths: paths)
        let text = tools.run("people", input: [:])
        XCTAssertTrue(text.contains("Sam asks for the answer first. (Likely, seen in 3 of 3 calls)"))
        XCTAssertTrue(text.contains("How to present to Sam Carter: Open with: Open with the answer."))
        let samPart = text.components(separatedBy: "Riley Chen |").first ?? ""
        XCTAssertFalse(samPart.contains("The coach's read (from"), "the old read goes once the person has a card")
        XCTAssertTrue(text.contains("The coach's read (from 2 calls)"), "Riley has no card yet: the old read with its count")
        let off = ChatTools(records: ProcessingQueue(paths: paths).allRecords(), owner: "Dana Lee", paths: paths, personaTraits: false).run("people", input: [:])
        XCTAssertFalse(off.contains("How they think"))
        XCTAssertFalse(MCPServer(paths: paths, owner: "Dana Lee", personaTraits: false).handle(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"people","arguments":{}}}"#)?.contains("How they think") ?? true)
        XCTAssertTrue(MCPServer(paths: paths, owner: "Dana Lee").handle(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"people","arguments":{}}}"#)?.contains("How they think") ?? false, "on by the owner's choice")
    }

    func testThePrepPageShowsTwoFullCardsAtMostForInvitedPeopleOnASureMatch() {
        let a = person("Sam Carter"), b = person("Riley Chen"), c = person("Jo Park")
        let saved = CoachPeople(people: [person("Dana Lee", owner: true), a, b, c])
        var reads: [String: PersonaSummary] = [:]
        for (p, extra) in [(a, 1), (b, 3), (c, 2)] {
            var s = PersonaSummary.make(persona(p.id.rawValue, card: true), answers: [], name: p.displayName)!
            s.traits += Array(repeating: s.traits[0], count: extra)
            reads[p.id.rawValue] = s
        }
        let coach = PrepCoach(people: ["Sam Carter", "Riley Chen", "Jo Park", "Sam"], profile: CoachProfile(), saved: saved, reads: reads)
        XCTAssertEqual(coach.people.map(\.name), ["Sam Carter", "Riley Chen", "Jo Park"], "a first name alone is no person")
        XCTAssertEqual(coach.people.filter(\.showsCard).map(\.name), ["Riley Chen", "Jo Park"])
        XCTAssertEqual(coach.people.first?.headline, "Open with the answer.", "the others show the headline")
    }

    func testTheSwitchForAPersonIsKeptAndStopsTheirRead() throws {
        let sam = person("Sam Carter")
        let store = PeopleStore(directory: paths.people)
        try store.replaceAll([person("Dana Lee", owner: true), sam])
        try store.setDoNotProfile(true, for: sam.id)
        XCTAssertEqual(PeopleStore(directory: paths.people).person(sam.id)?.doNotProfile, true)
        try PersonaStore(paths: paths).save(persona(sam.id.rawValue, card: true))
        let saved = CoachPeople.read(paths: paths)
        XCTAssertTrue(PersonaReads.all(paths: paths, saved: saved, answers: []).isEmpty)
        XCTAssertNil(PersonaReads.one(sam.id.rawValue, paths: paths, saved: saved, answers: []))
        try store.setDoNotProfile(false, for: sam.id)
        XCTAssertNotNil(PersonaReads.one(sam.id.rawValue, paths: paths, saved: CoachPeople.read(paths: paths), answers: []))
    }
}
