import XCTest
@testable import MossadCore

/// The payloads the Mac sends to the owner's server, as files the server's tests read (`server/test/fixtures`): a
/// renamed field fails here or there, never in silence. `MOSSAD_WRITE_FIXTURES=1 swift test --filter
/// ServerPayloadFixtureTests` writes them again after a deliberate change.
final class ServerPayloadFixtureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("server/test/fixtures")
    }

    private var people: [Person] {
        var sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: t0)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: t0)]
        sam.directory = DirectoryDetails(jobTitle: "Staff Engineer", department: "Platform", photoURL: nil, source: .googleDirectory, updated: t0)
        var dana = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", origin: .migration, at: t0)
        dana.doNotProfile = true
        return [Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: t0), sam, dana]
    }

    private func payloads() throws -> [String: Data] {
        var p = Persona(person: "id-sam", updated: t0)
        p.evidence = [1, 4, 7, 10, 13, 16].map { PersonaTraitsTests.moment($0) }
        p.texts["id-sam|order|answer_first|any"] = PersonaText(statement: "Sam asks for the answer first.", soDoThis: "Open with the answer.", rating: .medium,
                                                              written: t0, calls: 3, counter: 0)
        let read = try XCTUnwrap(PersonaSummary.make(p, answers: [], name: "Sam"))

        var book = NextTimeBook()
        var point = try XCTUnwrap(book.add("Ask about hiring", personID: "id-sam", personName: "Sam Carter", at: t0))
        point.id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var done = point
        done.id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        done.text = "Thank Sam"
        done.done = NextTimePoint.Discussed(callID: "c1", at: 65, quote: "thanks for the demo", date: t0, byOwner: false)
        book.points = [point, done]

        var tasks = CommitmentBook()
        var c = Commitment(text: "Send the forecast", to: "Sam Carter", callID: "c1", callTitle: "Planning", madeAt: t0, due: t0, created: t0)
        c.id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        c.toID = "id-sam"
        c.updated = t0
        tasks.items = [c]

        var profile = CoachProfile()
        profile.updateFacts(add: [CoachFact(kind: .role, text: "Head of data")], remove: [], at: t0)
        var sam = CoachPerson(note: "Sam NOTE", calls: 2, lastSeen: t0)
        sam.person = "id-sam"
        var dana = CoachPerson(note: "Dana NOTE", calls: 2, lastSeen: t0)
        dana.person = "id-dana"
        profile.people = ["Sam Carter": sam, "Dana Lee": dana]

        var chat = Chat(title: "Pitch")
        chat.id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        chat.created = t0
        chat.updated = t0
        chat.summary = "Planned the pitch."
        var m = ChatMessage(role: .user, text: "How do I pitch?")
        m.id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        chat.messages = [m]

        return ["people": SharedPayload.people(people).data, "personas": SharedPayload.personas(SyncedPersonas([read])).data,
                "next-time": SharedPayload.nextTime(book).data, "commitments": SharedPayload.commitments(tasks).data,
                "coach-profile": SharedPayload.profile(profile, people: people).data, "chat": SharedPayload.chat(chat).data]
    }

    func testThePayloadsAreTheFilesTheServersTestsRead() throws {
        let write = ProcessInfo.processInfo.environment["MOSSAD_WRITE_FIXTURES"] == "1"
        for (name, data) in try payloads() {
            let url = folder.appendingPathComponent("\(name).json")
            if write {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
                try pretty.write(to: url)
                continue
            }
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
            let now = try JSONSerialization.jsonObject(with: data) as? NSDictionary
            XCTAssertEqual(saved, now, "\(name): the Mac's payload changed; write the fixtures again and check the server's tools")
        }
        let profile = String(decoding: try XCTUnwrap(payloads()["coach-profile"]), as: UTF8.self)
        XCTAssertFalse(profile.contains("Dana NOTE"), "never on the server")
    }
}
