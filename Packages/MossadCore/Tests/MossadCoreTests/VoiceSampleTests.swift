import XCTest
@testable import MossadCore

/// Voice samples belong to a person id, and each one knows the call it came from.
final class VoiceSampleTests: XCTestCase {
    var root: URL!
    var library: VoiceLibrary!
    var people: PeopleStore!
    var samples: VoiceSampleStore!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() {
        root = tempDirectory()
        library = VoiceLibrary(directory: root.appendingPathComponent("Voices"))
        people = PeopleStore(directory: root.appendingPathComponent("People"))
        samples = VoiceSampleStore(directory: root.appendingPathComponent("Voices"))
        // A whole second, as the file keeps it.
        let at = t0
        library.identity = VoiceIdentity(people: people, samples: samples, now: { at })
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func source(_ call: String, _ key: String, seconds: Double = 30, quality: Double = 0.8, origin: VoiceSample.Origin = .ownerNamed) -> VoiceSampleSource {
        VoiceSampleSource(callID: call, speakerKey: key, recorded: t0, seconds: seconds, quality: quality, origin: origin)
    }

    /// A unit vector at an angle, so two of them have a known cosine.
    private func voice(_ degrees: Double) -> [Float] { [Float(cos(degrees * .pi / 180)), Float(sin(degrees * .pi / 180)), 0, 0] }

    private func mine(_ name: String) -> [VoiceSample] { people.id(forVoiceName: name).map(samples.samples(of:)) ?? [] }

    // MARK: Provenance

    func testALearnedSampleHasItsPersonAndWhereItCameFrom() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B", seconds: 42, quality: 0.9, origin: .autoMatch(0.86)))
        let id = try XCTUnwrap(people.id(forVoiceName: "Sam Carter"))
        let s = try XCTUnwrap(samples.samples.first)
        XCTAssertEqual(samples.samples.count, 1)
        XCTAssertEqual(s.personID, id)
        XCTAssertEqual(s.vector, voice(0))
        XCTAssertEqual(s.callID, "call-1")
        XCTAssertEqual(s.speakerKey, "them:B")
        XCTAssertEqual(s.track, "them")
        XCTAssertEqual(s.recorded, t0)
        XCTAssertEqual(s.seconds, 42)
        XCTAssertEqual(s.quality, 0.9)
        XCTAssertEqual(s.origin, .autoMatch(0.86))
        XCTAssertEqual(s.model, "fluidaudio:4")
    }

    func testTheFileHoldsTheNumbersExactlyAndReadsBack() throws {
        let vector: [Float] = [0.1234567, -0.7654321, 1e-7, 3.4e12]
        try library.add(vector, to: "Sam Carter", source: source("call-1", "them:B"))
        let back = VoiceSampleStore(directory: root.appendingPathComponent("Voices"))
        XCTAssertNil(back.loadError)
        XCTAssertEqual(back.samples, samples.samples)
        XCTAssertEqual(back.samples.first?.vector, vector)
        let text = try String(contentsOf: root.appendingPathComponent("Voices/samples.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("0.1234"), "the numbers are bytes, not decimal text")
    }

    func testTheVoiceFileOfTodayStaysCurrent() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        try library.add(voice(40), to: "Sam Carter", source: source("call-2", "them:A"))
        try library.setEmail("sam@example.com", for: "Sam Carter")
        // An old build reads the same file as before.
        let old = try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: root.appendingPathComponent("Voices/voices.json")))
        XCTAssertEqual(old, [VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [voice(0), voice(40)], email: "sam@example.com")])
        XCTAssertEqual(mine("Sam Carter").map(\.vector), [voice(0), voice(40)], "one sample for each fingerprint of the profile, in its order")
        XCTAssertEqual(people.people.first?.email, "sam@example.com")
    }

    func testALibraryWithNoPeopleStoreWorksAsBefore() throws {
        let plain = VoiceLibrary(directory: root.appendingPathComponent("Plain"))
        try plain.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        try plain.add(voice(1), to: "Sam Carter", source: source("call-1", "them:B"))
        try plain.forget(callID: "call-1", speakerKey: "them:B", from: "Sam Carter")
        XCTAssertEqual(plain.profiles.first?.embeddings.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plain/samples.json").path))
    }

    // MARK: A sample learned again

    func testTheSameCallAndSpeakerLearnedAgainReplacesTheSample() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        try library.add(voice(60), to: "Sam Carter", source: source("call-2", "them:A"))
        // "Transcribe again": the fingerprint of the same speaker is a little different.
        try library.add(voice(3), to: "Sam Carter", source: source("call-1", "them:B"))
        XCTAssertEqual(library.profiles.first?.embeddings, [voice(60), voice(3)], "the old one is gone from the voice file too")
        XCTAssertEqual(mine("Sam Carter").map(\.callID), ["call-2", "call-1"])
        XCTAssertEqual(samples.samples.count, 2)
    }

    func testANearCopyFromTheSameCallUnderANewKeyReplacesTheSample() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        // The new transcript gave the speaker another letter. Cosine of 5 degrees is 0.996.
        try library.add(voice(5), to: "Sam Carter", source: source("call-1", "them:A"))
        XCTAssertEqual(library.profiles.first?.embeddings, [voice(5)])
        XCTAssertEqual(mine("Sam Carter").map(\.speakerKey), ["them:A"])
    }

    func testAnotherVoiceOfTheSameCallIsASecondSample() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        // The person spoke on two tracks, and the two fingerprints differ. Cosine of 30 degrees is 0.87.
        try library.add(voice(30), to: "Sam Carter", source: source("call-1", "me:C"))
        XCTAssertEqual(library.profiles.first?.embeddings.count, 2)
    }

    func testANearCopyFromAnotherCallIsASecondSample() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        try library.add(voice(2), to: "Sam Carter", source: source("call-2", "them:B"))
        XCTAssertEqual(library.profiles.first?.embeddings.count, 2, "two calls are two samples, however alike")
    }

    func testTheSameSampleAgainIsOneSampleAndGetsItsCallWhenItHadNone() throws {
        try library.add(voice(0), to: "Sam Carter")
        XCTAssertNil(mine("Sam Carter").first?.callID)
        let id = mine("Sam Carter").first?.id
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:B"))
        XCTAssertEqual(library.profiles.first?.embeddings.count, 1)
        XCTAssertEqual(mine("Sam Carter").map(\.callID), ["call-1"])
        XCTAssertEqual(mine("Sam Carter").first?.id, id)
    }

    func testTheReplaceRuleNeedsTheSameCall() {
        let old = VoiceSample(personID: nil, vector: voice(0), source: source("call-1", "them:B"), learned: t0)
        XCTAssertEqual(VoiceSamples.replaced(by: voice(40), callID: "call-1", speakerKey: "them:B", among: [old]), [old], "the same key")
        XCTAssertEqual(VoiceSamples.replaced(by: voice(11), callID: "call-1", speakerKey: "them:A", among: [old]), [old], "cosine 0.982")
        XCTAssertEqual(VoiceSamples.replaced(by: voice(12), callID: "call-1", speakerKey: "them:A", among: [old]), [], "cosine 0.978")
        XCTAssertEqual(VoiceSamples.replaced(by: voice(1), callID: "call-2", speakerKey: "them:B", among: [old]), [])
        XCTAssertEqual(VoiceSamples.replaced(by: voice(1), callID: nil, speakerKey: nil, among: [old]), [])
    }

    // MARK: The limit

    func testTheSamplesFollowTheProfilesLimit() throws {
        for i in 0..<(VoiceLibrary.maxEmbeddings + 3) { try library.add(voice(Double(i) * 4), to: "Sam Carter", source: source("call-\(i)", "them:A")) }
        XCTAssertEqual(library.profiles.first?.embeddings.count, VoiceLibrary.maxEmbeddings)
        XCTAssertEqual(mine("Sam Carter").map(\.vector), library.profiles.first?.embeddings)
        XCTAssertEqual(mine("Sam Carter").first?.callID, "call-3")
    }

    // MARK: A correction

    func testThatWasNotSamTakesTheSampleBackFromSam() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:A"))
        try library.add(voice(60), to: "Sam Carter", source: source("call-2", "them:B"))
        try library.forget(callID: "call-2", speakerKey: "them:B", from: "Sam Carter")
        try library.add(voice(60), to: "Dana Lee", source: source("call-2", "them:B"))
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.embeddings, [voice(0)])
        XCTAssertEqual(library.profiles.first { $0.name == "Dana Lee" }?.embeddings, [voice(60)])
        XCTAssertEqual(mine("Sam Carter").map(\.callID), ["call-1"])
        XCTAssertEqual(mine("Dana Lee").map(\.callID), ["call-2"])
        // A call that taught nothing changes nothing.
        try library.forget(callID: "call-9", speakerKey: "them:B", from: "Sam Carter")
        try library.forget(callID: "call-1", speakerKey: "them:A", from: "Nobody Saved")
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.embeddings, [voice(0)])
    }

    // MARK: Rename, merge, delete

    func testARenameKeepsTheIdAndTheSamples() throws {
        try library.add(voice(0), to: "Dana Lee", source: source("call-1", "them:A"))
        let id = try XCTUnwrap(people.id(forVoiceName: "Dana Lee"))
        try library.rename("Dana Lee", to: "Dana Park")
        XCTAssertEqual(people.id(forVoiceName: "Dana Park"), id)
        XCTAssertEqual(people.person(id)?.forms.map(\.text), ["Dana Lee", "Dana Park"])
        XCTAssertEqual(samples.samples(of: id).count, 1)
    }

    func testAMergeMovesTheSamplesAndKeepsBothEmails() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:A"))
        try library.setEmail("sam@example.com", for: "Sam Carter")
        try library.add(voice(60), to: "Carter, Sam", source: source("call-2", "them:B"))
        try library.setEmail("s.carter@example.org", for: "Carter, Sam")
        let kept = try XCTUnwrap(people.id(forVoiceName: "Sam Carter")), gone = try XCTUnwrap(people.id(forVoiceName: "Carter, Sam"))
        try library.merge("Carter, Sam", into: "Sam Carter")
        XCTAssertEqual(library.profiles.map(\.name), ["Sam Carter"])
        XCTAssertEqual(library.profiles.first?.email, "sam@example.com", "the voice file keeps one email, as before")
        XCTAssertEqual(Set(samples.samples(of: kept).compactMap(\.callID)), ["call-1", "call-2"])
        XCTAssertTrue(samples.samples(of: gone).isEmpty)
        XCTAssertEqual(people.canonical(gone), kept)
        XCTAssertEqual(Set(people.person(kept)?.emails.map(\.address) ?? []), ["sam@example.com", "s.carter@example.org"])
        XCTAssertEqual(Set(people.person(kept)?.forms.map(\.text) ?? []), ["Sam Carter", "Carter, Sam"])
    }

    func testADeletedPersonTakesTheirSamples() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:A"))
        try library.add(voice(60), to: "Dana Lee", source: source("call-1", "them:B"))
        let id = try XCTUnwrap(people.id(forVoiceName: "Sam Carter"))
        try library.delete("Sam Carter")
        XCTAssertEqual(samples.samples.map(\.vector), [voice(60)])
        XCTAssertNotNil(people.person(id)?.deleted)
        XCTAssertNil(people.id(forVoiceName: "Sam Carter"))
    }

    func testDeleteAllVoicesKeepsThePeople() throws {
        try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:A"))
        let id = try XCTUnwrap(people.id(forVoiceName: "Sam Carter"))
        try library.deleteAll()
        XCTAssertTrue(samples.samples.isEmpty)
        XCTAssertEqual(people.people.filter(\.isLive).map(\.id), [id])
        // The voice named again is the same person.
        try library.add(voice(10), to: "Sam Carter", source: source("call-3", "them:A"))
        XCTAssertEqual(samples.samples.first?.personID, id)
    }

    func testTheOwnersProfileIsTheOwnerUnderAnyName() throws {
        try library.add(voice(0), to: "Avery Webb", isOwner: true, source: source("call-1", "me:A", origin: .ownerEnrollment))
        try people.setOwnerName("Avery Webb-Stone")
        // The voice file keeps the old name for the owner's profile. A match teaches that profile.
        try library.add(voice(20), to: "Avery Webb", source: source("call-2", "me:A", origin: .autoMatch(0.9)))
        XCTAssertEqual(people.people.filter(\.isLive).count, 1)
        XCTAssertEqual(samples.samples(of: try XCTUnwrap(people.owner?.id)).count, 2)
    }

    // MARK: A failure of the new stores

    func testAPeopleStoreThatCannotSaveNeverFailsTheVoiceLibrary() throws {
        let dir = root.appendingPathComponent("Newer")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":99,"people":[]}"#.utf8).write(to: dir.appendingPathComponent(PeopleStore.fileName))
        library.identity = VoiceIdentity(people: PeopleStore(directory: dir), samples: samples)
        XCTAssertNoThrow(try library.add(voice(0), to: "Sam Carter", source: source("call-1", "them:A")))
        XCTAssertEqual(library.profiles.first?.embeddings, [voice(0)])
        XCTAssertTrue(samples.samples.isEmpty, "no sample without its person")
    }

    // MARK: Quality

    func testQualityGrowsWithSpeechAndAgreementAndFallsWithEcho() {
        XCTAssertEqual(VoiceSample.quality(seconds: 30, coherence: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(VoiceSample.quality(seconds: 60, coherence: 1), 1, accuracy: 0.0001, "30 seconds is enough")
        XCTAssertEqual(VoiceSample.quality(seconds: 15, coherence: 1), 0.75, accuracy: 0.0001)
        XCTAssertEqual(VoiceSample.quality(seconds: 30, coherence: 0.75), 0.75, accuracy: 0.0001)
        XCTAssertEqual(VoiceSample.quality(seconds: 30, coherence: nil), 0.75, accuracy: 0.0001, "one piece agrees with nothing")
        XCTAssertEqual(VoiceSample.quality(seconds: 30, coherence: 1, echoShare: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VoiceSample.quality(seconds: 0, coherence: 0.2), 0, accuracy: 0.0001)
        XCTAssertLessThan(VoiceSample.quality(seconds: 4, coherence: 0.9), VoiceSample.quality(seconds: 40, coherence: 0.9))
    }

    func testTheSpeechAFingerprintUsesIsCountedFromTheLines() {
        func line(_ start: Double, _ end: Double) -> Utterance { Utterance(track: .them, speakerLabel: "A", start: start, end: end, text: "x") }
        XCTAssertEqual(SpeakerIdentifier.speechUsed([line(0, 1.5)]), 0, "a line under 2 seconds is not used")
        XCTAssertEqual(SpeakerIdentifier.speechUsed([line(0, 5), line(10, 13)]), 8)
        XCTAssertEqual(SpeakerIdentifier.speechUsed([line(0, 25)]), 25, "in pieces of 10, 10, and 5")
        XCTAssertEqual(SpeakerIdentifier.speechUsed([line(0, 11)]), 10, "a last piece under 2 seconds is left")
        XCTAssertEqual(SpeakerIdentifier.speechUsed([line(0, 50), line(100, 150)]), 60, "60 seconds at most")
    }
}
