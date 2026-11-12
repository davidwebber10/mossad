import XCTest
@testable import MossadCore

final class VoiceLibraryTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = tempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testDeleteAllRemovesEveryVoice() throws {
        let library = VoiceLibrary(directory: dir)
        try library.add([1, 0, 0], to: "A", isOwner: true)
        try library.add([0, 1, 0], to: "B")
        try library.deleteAll()
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertTrue(VoiceLibrary(directory: dir).profiles.isEmpty)
    }

    func testBestMatchAboveThreshold() throws {
        let lib = VoiceLibrary(directory: dir)
        try lib.add([1, 0, 0], to: "Alex Rivera")
        let match = try XCTUnwrap(lib.bestMatch([0.9, 0.3, 0]))
        XCTAssertEqual(match.name, "Alex Rivera")
        XCTAssertGreaterThanOrEqual(match.score, 0.65)
    }

    func testBelowThresholdReturnsNil() throws {
        let lib = VoiceLibrary(directory: dir)
        try lib.add([1, 0, 0], to: "Alex Rivera")
        XCTAssertEqual(lib.matchThreshold, 0.65)
        XCTAssertNil(lib.bestMatch([0.5, 1, 0]))
    }

    func testPicksClosestProfile() throws {
        let lib = VoiceLibrary(directory: dir)
        try lib.add([1, 0, 0], to: "Alex Rivera")
        try lib.add([0, 1, 0], to: "Amy Lee")
        XCTAssertEqual(lib.bestMatch([0.2, 1, 0])?.name, "Amy Lee")
    }

    func testAddCapsAtTwentyEmbeddings() throws {
        let lib = VoiceLibrary(directory: dir)
        for i in 0..<25 { try lib.add([1, Float(i), 0], to: "Alex Rivera") }
        let profile = try XCTUnwrap(lib.profiles.first)
        XCTAssertEqual(profile.embeddings.count, 20)
        XCTAssertEqual(profile.embeddings.last, [1, 24, 0])
    }

    func testEmailIsStoredAndFoundIgnoringCase() throws {
        let lib = VoiceLibrary(directory: dir)
        try lib.add([1, 0, 0], to: "Alex Rivera")
        try lib.setEmail("Alex@Example.com", for: "Alex Rivera")
        XCTAssertEqual(VoiceLibrary(directory: dir).name(forEmail: "alex@example.com"), "Alex Rivera")
        XCTAssertNil(lib.name(forEmail: "amy@example.com"))
        try lib.setEmail(nil, for: "Alex Rivera")
        XCTAssertNil(lib.name(forEmail: "alex@example.com"))
    }

    func testSetEmailForANewNameMakesAProfileWithoutVoice() throws {
        let lib = VoiceLibrary(directory: dir)
        try lib.setEmail("amy@example.com", for: "Amy Lee")
        XCTAssertEqual(lib.profiles.map(\.name), ["Amy Lee"])
        XCTAssertEqual(lib.profiles.first?.embeddings, [])
        XCTAssertNil(lib.bestMatch([1, 0, 0]))
    }

    func testRenameKeepsTheEmail() throws {
        let lib = VoiceLibrary(directory: dir)
        try lib.add([1, 0, 0], to: "Alex")
        try lib.setEmail("alex@example.com", for: "Alex")
        try lib.add([1, 0, 0], to: "Alex Rivera")
        try lib.merge("Alex", into: "Alex Rivera")
        XCTAssertEqual(lib.name(forEmail: "alex@example.com"), "Alex Rivera")
    }

    func testOldFileWithoutEmailsLoads() throws {
        let json = #"[{"name":"Alex Rivera","isOwner":false,"embeddings":[[1,0,0]]}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("voices.json"))
        let lib = VoiceLibrary(directory: dir)
        XCTAssertEqual(lib.profiles.map(\.name), ["Alex Rivera"])
        XCTAssertNil(lib.profiles.first?.email)
    }

    func testPersistsAcrossInstances() throws {
        try VoiceLibrary(directory: dir).add([0, 0, 1], to: "Avery Lane", isOwner: true)
        let reloaded = VoiceLibrary(directory: dir)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Avery Lane"])
        XCTAssertEqual(reloaded.owner?.name, "Avery Lane")
    }

    // A voice learned from one invite.

    func invited(_ call: String, _ key: String = "them:B") -> VoiceSampleSource {
        VoiceSampleSource(callID: call, speakerKey: key, origin: .inviteInference)
    }

    func testAVoiceFromTheInviteIsProvisionalUntilAnotherMeetingConfirmsIt() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func match(_ call: String, _ at: Date) -> VoiceSampleSource {
            VoiceSampleSource(callID: call, speakerKey: "them:A", recorded: at, origin: .autoMatch(0.95))
        }
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: VoiceSampleSource(callID: "call-1", speakerKey: "them:B", recorded: day, origin: .inviteInference))
        XCTAssertEqual(library.provisional, ["Jo Fenwick": "call-1"])
        try library.add([0, 0.99, 0.1, 0], to: "Jo Fenwick", source: match("call-1", day))
        XCTAssertEqual(library.provisional, ["Jo Fenwick": "call-1"])
        // A second record of the same meeting, after the call dropped and started again: no new proof.
        try library.add([0, 0.98, 0.2, 0], to: "Jo Fenwick", source: match("call-1b", day.addingTimeInterval(600)))
        XCTAssertEqual(library.provisional, ["Jo Fenwick": "call-1"])
        try library.add([0, 0.97, 0.2, 0.1], to: "Jo Fenwick", source: match("call-2", day.addingTimeInterval(7 * 86_400)))
        XCTAssertEqual(library.provisional, [:])
    }

    func testJoiningAProvisionalVoiceIntoAnotherKeepsOnlyWhatIsThatVoice() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: invited("call-1"))
        try library.add([0, 0, 1, 0], to: "Dale Fenwick")
        try library.merge("Jo Fenwick", into: "Dale Fenwick")
        XCTAssertEqual(library.profiles.first { $0.name == "Dale Fenwick" }?.embeddings, [[0, 0, 1, 0]])
        XCTAssertEqual(library.provisional, [:])
        try library.add([0, 1, 0, 0], to: "Pat Quill", source: invited("call-2"))
        try library.add([0, 0.99, 0.1, 0], to: "Robin Ash")
        try library.merge("Robin Ash", into: "Pat Quill")
        XCTAssertEqual(library.profiles.first { $0.name == "Pat Quill" }?.embeddings.count, 2)
        XCTAssertEqual(library.provisional, [:])
    }

    func testADirectoryNameForAPersonWithAVoiceRenamesTheVoice() throws {
        let dir = tempDirectory()
        let library = VoiceLibrary(directory: dir)
        let people = PeopleStore(directory: dir.appendingPathComponent("People"))
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: dir))
        try people.ensure(voiceName: "Robin Ash", isOwner: false, origin: .address)
        try library.add([0, 1, 0, 0], to: "Robin Ash", source: invited("call-1"))
        try library.setEmail("robin.ash@example.com", for: "Robin Ash", actor: "invite")
        let changed = try library.applyDirectory([GoogleProfile(emails: ["robin.ash@example.com"], name: "Rob Ashworth", source: .directory)])
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(library.profiles.map(\.name), ["Rob Ashworth"])
        XCTAssertEqual(library.provisional, ["Rob Ashworth": "call-1"])
        XCTAssertEqual(people.people.filter(\.isLive).map(\.displayName), ["Rob Ashworth"])
        // A later save of the voice finds the same person.
        try library.setEmail("robin.ash@example.com", for: "Rob Ashworth")
        XCTAssertEqual(people.people.filter(\.isLive).count, 1)
    }

    func testADirectoryRenameKeepsEveryAddressAndTheVoiceStaysProvisional() throws {
        let dir = tempDirectory()
        let library = VoiceLibrary(directory: dir)
        let people = PeopleStore(directory: dir.appendingPathComponent("People"))
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: dir))
        try people.ensure(voiceName: "Robin Ash", isOwner: false, origin: .address)
        try library.add([0, 1, 0, 0], to: "Robin Ash", source: invited("call-1"))
        try library.setEmail("robin.ash@example.com", for: "Robin Ash", actor: "invite")
        XCTAssertEqual(try library.addEmail("rash@example-group.test", for: "Robin Ash"), .added)
        // The directory knows the person by the second address only.
        let changed = try library.applyDirectory([GoogleProfile(emails: ["rash@example-group.test"], name: "Rob Ashworth", source: .directory)])
        XCTAssertEqual(changed, 1)
        let p = try XCTUnwrap(library.profiles.first)
        XCTAssertEqual(p.name, "Rob Ashworth")
        XCTAssertEqual(p.emails, ["robin.ash@example.com", "rash@example-group.test"])
        XCTAssertEqual(library.provisional, ["Rob Ashworth": "call-1"])
        let live = people.people.filter(\.isLive)
        XCTAssertEqual(live.map(\.displayName), ["Rob Ashworth"])
        XCTAssertEqual(Set(live[0].emails.filter { $0.state == .verified }.map(\.address)), ["robin.ash@example.com", "rash@example-group.test"])
    }

    func testTheInvitesAddressNeverGoesToASecondPerson() throws {
        let dir = tempDirectory()
        let library = VoiceLibrary(directory: dir)
        let people = PeopleStore(directory: dir.appendingPathComponent("People"))
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: dir))
        // Sam has the address as a second one; a voice named "Jo" from the invite does not take it.
        try library.setEmail("sam@example.com", for: "Sam Carter")
        XCTAssertEqual(try library.addEmail("team-lead@example.com", for: "Sam Carter"), .added)
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: invited("call-1"))
        XCTAssertEqual(try library.setEmail("team-lead@example.com", for: "Jo Fenwick", actor: "invite"), .belongsTo("Sam Carter"))
        XCTAssertEqual(library.profiles.first { $0.name == "Jo Fenwick" }?.emails, [])
        XCTAssertEqual(library.name(forEmail: "team-lead@example.com"), "Sam Carter")
    }

    func testTheOwnersNameForTheSameVoiceMakesItFirm() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: invited("call-1"))
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: VoiceSampleSource(callID: "call-1", speakerKey: "them:B", origin: .ownerNamed))
        XCTAssertEqual(library.provisional, [:])
        XCTAssertEqual(library.profiles.first?.embeddings, [[0, 1, 0, 0]])
    }

    func testTheOwnersNameForAnotherVoiceRemovesTheInvitesSample() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: invited("call-1"))
        try library.add([0, 0, 1, 0], to: "Jo Fenwick", source: VoiceSampleSource(callID: "call-3", speakerKey: "them:A", origin: .ownerNamed))
        XCTAssertEqual(library.provisional, [:])
        XCTAssertEqual(library.profiles.first?.embeddings, [[0, 0, 1, 0]])
    }

    func testTranscribeAgainKeepsTheInvitesOrigin() throws {
        let dir = tempDirectory()
        let library = VoiceLibrary(directory: dir)
        let people = PeopleStore(directory: dir.appendingPathComponent("People"))
        let samples = VoiceSampleStore(directory: dir)
        library.identity = VoiceIdentity(people: people, samples: samples)
        try library.add([0, 1, 0, 0], to: "Jo Fenwick", source: invited("call-1"))
        try library.add([0, 0.99, 0.1, 0], to: "Jo Fenwick", source: invited("call-1"))
        let id = try XCTUnwrap(people.id(forVoiceName: "Jo Fenwick"))
        XCTAssertEqual(samples.samples(of: id).map(\.origin), [.inviteInference])
        XCTAssertEqual(library.profiles.first?.embeddings, [[0, 0.99, 0.1, 0]])
        XCTAssertEqual(library.provisional, ["Jo Fenwick": "call-1"])
    }

    func testAProfileFromAnOlderBuildIsFirm() throws {
        let dir = tempDirectory()
        try Data(#"[{"name":"Mira Stone","isOwner":false,"embeddings":[[0,1,0,0]]}]"#.utf8).write(to: dir.appendingPathComponent("voices.json"))
        XCTAssertEqual(VoiceLibrary(directory: dir).provisional, [:])
    }
}
