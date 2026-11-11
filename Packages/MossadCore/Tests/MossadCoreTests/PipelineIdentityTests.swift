import XCTest
@testable import MossadCore

/// The pipeline tells the voice library which call and speaker each sample came from.
extension PipelineTests {
    private func attachIdentity() -> (people: PeopleStore, samples: VoiceSampleStore) {
        let people = PeopleStore(directory: paths.people), samples = VoiceSampleStore(directory: paths.voices)
        library.identity = VoiceIdentity(people: people, samples: samples)
        return (people, samples)
    }

    func testTheOwnersFirstSampleKnowsItsCallAndItsLength() async throws {
        let stores = attachIdentity()
        let id = try makeRecord()
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.speakerSamples?["me:A"]?.seconds, 10)
        XCTAssertEqual(r.speakerSamples?["them:B"]?.seconds, 7)
        XCTAssertNotNil(r.speakerSamples?["me:A"]?.quality)
        let owner = try XCTUnwrap(stores.people.owner)
        XCTAssertEqual(library.owner?.name, owner.displayName, "the owner's profile and the owner are one")
        let sample = try XCTUnwrap(stores.samples.samples(of: owner.id).first)
        XCTAssertEqual(sample.callID, id)
        XCTAssertEqual(sample.speakerKey, "me:A")
        XCTAssertEqual(sample.track, "me")
        XCTAssertEqual(sample.recorded, start)
        XCTAssertEqual(sample.seconds, 10)
        XCTAssertEqual(sample.origin, .ownerEnrollment)
        XCTAssertEqual(sample.quality, r.speakerSamples?["me:A"]?.quality)
    }

    func testANamedVoiceIsASampleOfThatPersonFromThatCall() async throws {
        let stores = attachIdentity()
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"], emails: ["them:B": "amy@example.com"])
        let amy = try XCTUnwrap(stores.people.id(forVoiceName: "Amy Lee"))
        XCTAssertEqual(stores.people.person(amy)?.email, "amy@example.com")
        let sample = try XCTUnwrap(stores.samples.samples(of: amy).first)
        XCTAssertEqual(sample.vector, [0, 0, 0, 1])
        XCTAssertEqual(sample.callID, id)
        XCTAssertEqual(sample.speakerKey, "them:B")
        XCTAssertEqual(sample.seconds, 7)
        XCTAssertEqual(sample.origin, .ownerNamed)
        XCTAssertEqual(stores.samples.samples.count, 3, "the owner, Alex, and Amy")
    }

    func testCorrectingANamedSpeakerTakesTheSampleBackFromTheFirstPerson() async throws {
        let stores = attachIdentity()
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Alex Rivera"])
        XCTAssertEqual(library.profiles.first { $0.name == "Alex Rivera" }?.embeddings.count, 2)
        // "That was not Alex."
        await p.applyNames(callID: id, names: ["them:B": "Amy Lee"])
        XCTAssertEqual(try load(id).speakerNames["them:B"], "Amy Lee")
        XCTAssertEqual(library.profiles.first { $0.name == "Alex Rivera" }?.embeddings, [[0, 1, 0, 0]], "Alex keeps only their own voice")
        XCTAssertEqual(library.profiles.first { $0.name == "Amy Lee" }?.embeddings, [[0, 0, 0, 1]])
        let alex = try XCTUnwrap(stores.people.id(forVoiceName: "Alex Rivera"))
        XCTAssertEqual(stores.samples.samples(of: alex).map(\.speakerKey), ["them:A"])
        // The same name again, in another written form, takes nothing back.
        await p.applyNames(callID: id, names: ["them:A": "Rivera, Alex"])
        XCTAssertEqual(try load(id).speakerNames["them:A"], "Alex Rivera")
        XCTAssertEqual(library.profiles.first { $0.name == "Alex Rivera" }?.embeddings, [[0, 1, 0, 0]])
    }

    /// A short first name is a guess. The voice gets the name as typed and its own profile, as before; it does not
    /// go into the profile of a saved person with another first name.
    func testAVoiceNamedWithAShortNameDoesNotJoinAnotherPerson() async throws {
        try library.add([0, 0, 1, 0], to: "Alexandra Rivera")
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera"])
        XCTAssertEqual(try load(id).speakerNames["them:A"], "Alex Rivera")
        XCTAssertEqual(library.profiles.first { $0.name == "Alexandra Rivera" }?.embeddings, [[0, 0, 1, 0]])
        XCTAssertEqual(library.profiles.first { $0.name == "Alex Rivera" }?.embeddings, [[0, 1, 0, 0]])
    }

    func testTranscribeAgainDoesNotGiveAPersonASecondSampleOfOneCall() async throws {
        let stores = attachIdentity()
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"])
        let before = stores.samples.samples.count
        let started = await p.transcribeAgain(id, speakers: nil)
        XCTAssertTrue(started)
        XCTAssertEqual(try load(id).status, .written)
        XCTAssertEqual(stores.samples.samples.count, before)
        for profile in library.profiles { XCTAssertEqual(profile.embeddings.count, 1, profile.name) }
        XCTAssertEqual(Set(stores.samples.samples.compactMap(\.callID)), [id])
    }

    /// "Your name" in Settings is new, and the owner's voice profile still has the old name. The owner's voice is
    /// also on the call audio (a second device in the room). The mic lines are the owner's, not an echo of a guest.
    func testTheOwnersMicLinesStayWhenTheProfileHasTheOwnersOldName() async throws {
        try library.add([1, 0, 0, 0], to: "Avery Webb", isOwner: true)
        let id = "20261020-143000", dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 200)])
        try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(1800), status: .recorded).save(to: dir)
        transcriber.result = [.me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Where is the shipment?")],
                              .them: [Utterance(track: .them, speakerLabel: "A", start: 11, end: 20, text: "It leaves Friday.")]]
        // The pipeline of these tests has another owner name than the profile.
        await pipeline().process(id)
        let r = try load(id)
        XCTAssertEqual(r.speakerNames["me:A"], "Avery Webb")
        XCTAssertTrue(r.utterances.contains { $0.track == .me }, "the owner's own lines are not dropped as an echo")
    }

    func testADeletedMeetingKeepsItsVoiceSamples() async throws {
        let stores = attachIdentity()
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera"])
        let before = stores.samples.samples
        let deleted = await p.delete(callID: id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(stores.samples.samples, before, "what Mossad learned from the meeting stays")
        XCTAssertEqual(library.bestMatch([0, 1, 0, 0])?.name, "Alex Rivera")
    }
}
