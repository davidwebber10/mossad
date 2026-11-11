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
        XCTAssertEqual(owner.displayName, "David Webber")
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
