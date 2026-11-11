import XCTest
@testable import MossadCore

/// The owner is a person, not the text in Settings. A new name there must not make the owner's old lines someone
/// else's: the commitment cleanup then marked the owner's own commitments as deleted, and the deletion synced.
final class OwnerIdentityTests: XCTestCase {
    var paths: Paths!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    /// A call where the owner, under the name of that time, promised something, and another person did too.
    private func record(_ id: String = "20261105-100000", owner: String? = "Avery Webb") -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["them:A": "Pat Moreno"]
        if let owner { r.speakerNames["me:A"] = owner }
        r.utterances = [
            Utterance(track: .them, speakerLabel: "A", start: 10, end: 14, text: "But let me confirm that, I'll check the flight."),
            Utterance(track: .me, speakerLabel: "A", start: 20, end: 26, text: "Okay. I'm gonna give you access to the budget sheet today."),
        ]
        return r
    }

    private func book(call: String = "20261105-100000") -> CommitmentBook {
        var book = CommitmentBook()
        book.add(found: [
            Commitment(text: "Give access", to: "Pat Moreno", callID: call, callTitle: "T", madeAt: t0, at: 20, quote: "give you access", due: nil),
            Commitment(text: "Confirm the flight", to: nil, callID: call, callTitle: "T", madeAt: t0, at: 10, quote: "let me confirm that", due: nil),
        ], callID: call, at: t0)
        book.items.append(Commitment(text: "Mine by hand", to: nil, callID: nil, callTitle: nil, madeAt: t0, due: nil))
        return book
    }

    // MARK: The identity

    func testTheOwnerIsEachNameTheyHaveOrHad() {
        let owner = OwnerIdentity(name: "Avery Webb-Stone", also: ["Avery Webb", " "])
        XCTAssertTrue(owner.isOwner("Avery Webb-Stone"))
        XCTAssertTrue(owner.isOwner("Avery Webb"))
        XCTAssertTrue(owner.isOwner("avery  WEBB"), "in any case and spacing")
        XCTAssertFalse(owner.isOwner("Avery"))
        XCTAssertFalse(owner.isOwner("Pat Moreno"))
        XCTAssertFalse(owner.isOwner(""))
        XCTAssertEqual(owner.speakerKeys(in: record()), ["me:A"])
        XCTAssertEqual(owner.name(in: record()), "Avery Webb", "the name the transcript of that call shows")
        XCTAssertEqual(owner.name(in: record(owner: nil)), "Avery Webb-Stone")
        XCTAssertEqual(OwnerIdentity(name: "Avery Webb"), "Avery Webb")
    }

    func testTheIdentityIsReadFromThePeopleAndTheVoiceLibrary() throws {
        // The voice library keeps the name the owner's profile was made with.
        try VoiceLibrary(directory: paths.voices).add([1, 0, 0, 0], to: "Avery Webb", isOwner: true)
        XCTAssertTrue(OwnerIdentity.read(name: "A. Webb-Stone", paths: paths).isOwner("Avery Webb"))
        // The people store keeps each former name.
        let people = PeopleStore(directory: paths.people)
        try people.setOwnerName("Avery W")
        try people.setOwnerName("A. Webb-Stone")
        let owner = OwnerIdentity.read(name: "A. Webb-Stone", paths: paths)
        XCTAssertTrue(owner.isOwner("Avery W") && owner.isOwner("Avery Webb") && owner.isOwner("A. Webb-Stone"))
        XCTAssertFalse(owner.isOwner("Pat Moreno"))
    }

    /// The owner typed another person's name in "Your name" by mistake, pressed Return, and corrected it. That
    /// person's lines are not the owner's.
    func testAFormerNameThatIsAnotherSavedPersonsNameIsNotTheOwners() throws {
        let people = PeopleStore(directory: paths.people)
        try people.setOwnerName("Avery Webb")
        _ = try people.ensure(voiceName: "Pat Moreno", isOwner: false, origin: .voiceNaming)
        try people.setOwnerName("Pat Moreno")
        try people.setOwnerName("Avery Webb")
        XCTAssertEqual(Set(people.ownerNames), ["Pat Moreno", "Avery Webb"], "the store keeps what was typed")
        let owner = OwnerIdentity.read(name: "Avery Webb", paths: paths)
        XCTAssertFalse(owner.isOwner("Pat Moreno"))
        XCTAssertTrue(owner.isOwner("Avery Webb"))
        XCTAssertEqual(owner.speakerKeys(in: record()), ["me:A"])
    }

    func testReadingTheIdentityMovesNoDamagedFileAside() throws {
        try Data("nope".utf8).write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        try Data("nope".utf8).write(to: paths.voices.appendingPathComponent("voices.json"))
        XCTAssertEqual(OwnerIdentity.read(name: "Avery Webb", paths: paths), "Avery Webb")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.people.path), [PeopleStore.fileName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.voices.path), ["voices.json"])
    }

    // MARK: The cleanup

    func testANewOwnerNameDoesNotDeleteTheOwnersCommitments() {
        var book = book()
        // The records still carry the old name. The owner's identity knows it.
        book.dropOthers(records: [record()], owner: OwnerIdentity(name: "Avery Webb-Stone", also: ["Avery Webb"]), at: t0)
        XCTAssertEqual(book.visible.map(\.text), ["Give access", "Mine by hand"], "the owner's stays; the other person's goes, as before")
    }

    func testACallWithNoLineOfTheOwnerSaysNothing() {
        var book = book()
        // The name changed and nothing knows the old one: whose line it was is unknown, and unknown is not "not the owner's".
        book.dropOthers(records: [record()], owner: OwnerIdentity(name: "Avery Webb-Stone"), at: t0)
        XCTAssertEqual(book.visible.map(\.text), ["Give access", "Confirm the flight", "Mine by hand"])
        XCTAssertFalse(book.items.contains(where: \.deleted))
    }

    func testTheRunAfterANameChangeDeletesNothingOfTheOwners() async throws {
        let r = record()
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
        try book().save(to: paths.commitments)
        try VoiceLibrary(directory: paths.voices).add([1, 0, 0, 0], to: "Avery Webb", isOwner: true)
        // "Your name" in Settings is new. No model request is needed: the call was read before.
        let finder = CommitmentFinder(llm: AnthropicModel(apiKey: "k", model: "m", session: StubURLProtocol.session(), usage: nil), ownerName: "Avery Webb-Stone")
        let runner = CommitmentRunner(paths: paths, finder: finder, since: t0.addingTimeInterval(-86_400))
        _ = await runner.run()
        let after = try CommitmentBook.load(from: paths.commitments)
        XCTAssertEqual(after.visible.map(\.text), ["Give access", "Mine by hand"])
        XCTAssertEqual(after.items.filter(\.deleted).map(\.text), ["Confirm the flight"])
    }

    func testTheRunWithNoKnownOldNameDeletesNothing() async throws {
        let r = record()
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
        try book().save(to: paths.commitments)
        let finder = CommitmentFinder(llm: AnthropicModel(apiKey: "k", model: "m", session: StubURLProtocol.session(), usage: nil), ownerName: "Avery Webb-Stone")
        _ = await CommitmentRunner(paths: paths, finder: finder, since: t0.addingTimeInterval(-86_400)).run()
        XCTAssertFalse(try CommitmentBook.load(from: paths.commitments).items.contains(where: \.deleted))
    }

    // MARK: CoachFinding

    func testANewCallUnderTheOldProfileNameIsStillReadForTheOwnersPromises() async throws {
        let out: [String: Any] = ["commitments": [["text": "Give access to the budget sheet", "to": "Pat Moreno", "due": NSNull(),
                                                   "quote": "I'm gonna give you access", "at_seconds": 20]]]
        StubURLProtocol.handler = { _ in (200, json(["stop_reason": "end_turn", "content": [["type": "text", "text": String(decoding: json(out), as: UTF8.self)]]])) }
        var finder = CommitmentFinder(llm: AnthropicModel(apiKey: "k", model: "m", session: StubURLProtocol.session(), usage: nil), ownerName: "Avery Webb-Stone")
        finder.owner = OwnerIdentity(name: "Avery Webb-Stone", also: ["Avery Webb"])
        let found = try await finder.find(in: record())
        XCTAssertEqual(found.map(\.text), ["Give access to the budget sheet"])
        let body = String(decoding: try XCTUnwrap(StubURLProtocol.requests.last).body, as: UTF8.self)
        XCTAssertTrue(body.contains("Only lines spoken by Avery Webb count"), "the model gets the name the transcript shows")
    }

    func testACallWithNoLineOfTheOwnerIsNotSentToTheModel() async throws {
        StubURLProtocol.requests = []
        StubURLProtocol.handler = { _ in (500, Data()) }
        let finder = CommitmentFinder(llm: AnthropicModel(apiKey: "k", model: "m", session: StubURLProtocol.session(), usage: nil), ownerName: "Avery Webb")
        let found = try await finder.find(in: record(owner: nil))
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "nothing can count there, so nothing is billed")
    }
}
