import XCTest
@testable import MossadCore

final class SpeakerIdentifierTests: XCTestCase {
    var dir: URL!
    var library: VoiceLibrary!
    let provider = ToneEmbeddingProvider()
    var meURL: URL { dir.appendingPathComponent("me.caf") }
    var themURL: URL { dir.appendingPathComponent("them.caf") }

    override func setUp() {
        dir = tempDirectory()
        library = VoiceLibrary(directory: dir.appendingPathComponent("Voices"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func u(_ track: Track, _ label: String, _ start: Double, _ end: Double) -> Utterance {
        Utterance(track: track, speakerLabel: label, start: start, end: end, text: "words")
    }

    func identify(_ utterances: [Utterance]) async throws -> SpeakerIdentification {
        try await SpeakerIdentifier(library: library, provider: provider, ownerName: "Avery Lane").identify(utterances: utterances, meURL: meURL, themURL: themURL)
    }

    func testOwnerEnrolledFromDominantMeSpeakerWhenLibraryHasNoOwner() async throws {
        try writeSegments(meURL, total: 30, [(0, 10, 200), (20, 23, 600)])
        try writeSegments(themURL, total: 30, [])
        let result = try await identify([u(.me, "A", 0, 10), u(.me, "B", 20, 23)])
        XCTAssertEqual(result.names["me:A"], "Avery Lane")
        XCTAssertEqual(library.owner?.name, "Avery Lane")
        XCTAssertEqual(result.unknown, ["me:B"])
    }

    func testOwnerIsNotEnrolledFromEchoOfTheOtherSide() async throws {
        // me:A is the other side leaking into the mic: it talks most, but only while them:A talks.
        try writeSegments(meURL, total: 60, [(0, 30, 600), (40, 50, 200)])
        try writeSegments(themURL, total: 60, [(0, 30, 400)])
        let result = try await identify([u(.me, "A", 0, 30), u(.them, "A", 0, 30), u(.me, "B", 40, 50)])
        XCTAssertEqual(result.names["me:B"], "Avery Lane")
        XCTAssertNotEqual(result.names["me:A"], "Avery Lane")
    }

    func testOwnerIsNotEnrolledFromSlightlyLateEcho() async throws {
        // David only listens; the echo on his mic is 0.1 s late.
        try writeSegments(meURL, total: 60, [(0.1, 30.1, 600)])
        try writeSegments(themURL, total: 60, [(0, 30, 400)])
        let result = try await identify([u(.me, "A", 0.1, 30.1), u(.them, "A", 0, 30)])
        XCTAssertNotEqual(result.names["me:A"], "Avery Lane")
        XCTAssertNil(library.owner)
    }

    func testOwnerIsNotEnrolledWhenMostOfTheSpeechIsEcho() async throws {
        // One mic label holds 60 s of echo and 6 s alone: the fingerprint would be mostly the other voice.
        try writeSegments(meURL, total: 80, [(0, 60, 600), (70, 76, 200)])
        try writeSegments(themURL, total: 80, [(0, 60, 400)])
        let result = try await identify([u(.me, "A", 0, 60), u(.them, "A", 0, 60), u(.me, "A", 70, 76)])
        XCTAssertNotEqual(result.names["me:A"], "Avery Lane")
        XCTAssertNil(library.owner)
    }

    func testOwnerMatchedByVoiceOnMeTrack() async throws {
        try library.add([1, 0, 0, 0], to: "Avery Lane", isOwner: true)
        try writeSegments(meURL, total: 30, [(0, 3, 600), (5, 20, 200)])
        try writeSegments(themURL, total: 30, [])
        let result = try await identify([u(.me, "A", 0, 3), u(.me, "B", 5, 20)])
        XCTAssertEqual(result.names["me:B"], "Avery Lane")
        XCTAssertNil(result.names["me:A"])
        XCTAssertEqual(result.unknown, ["me:A"])
    }

    func testThemSpeakerMatchesKnownColleague() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 12, 400), (13, 18, 800)])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 12), u(.them, "B", 13, 18)])
        XCTAssertEqual(result.names["them:A"], "Alex Rivera")
        XCTAssertEqual(result.unknown, ["them:B"])
        XCTAssertEqual(result.embeddings["them:B"], [0, 0, 0, 1])
    }

    func testTwoLabelsSameVoiceGetSameName() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 10, 400), (12, 16, 400)])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 10), u(.them, "C", 12, 16)])
        XCTAssertEqual(result.names["them:A"], "Alex Rivera")
        XCTAssertEqual(result.names["them:C"], "Alex Rivera")
    }

    func testMatchedSpeakerAddsEmbeddingToProfile() async throws {
        try library.add([0, 0.995, 0.1, 0], to: "Alex Rivera")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 12, 400)])
        _ = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 12)])
        XCTAssertEqual(library.profiles.first { $0.name == "Alex Rivera" }?.embeddings.count, 2)
    }

    func testSpeakerWithUnderTwoSecondsIsUnknown() async throws {
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 7.5, 400)])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 7.5)])
        XCTAssertNil(result.names["them:A"])
        XCTAssertEqual(result.unknown, ["them:A"])
        XCTAssertNil(result.embeddings["them:A"])
    }

    func testWeakMatchNamesButDoesNotLearn() async throws {
        // [0.7, 0.71, 0, 0]-ish: the 400 Hz voice scores ~0.71 against this profile — above 0.65, below 0.8.
        try library.add([0.7, 0.71, 0, 0], to: "Alex Rivera")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 12, 400)])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 12)])
        XCTAssertEqual(result.names["them:A"], "Alex Rivera")
        XCTAssertEqual(library.profiles.first { $0.name == "Alex Rivera" }?.embeddings.count, 1)
    }

    // The invite.

    func identify(_ utterances: [Utterance], invite: CallInvite?) async throws -> SpeakerIdentification {
        try await SpeakerIdentifier(library: library, provider: provider, ownerName: "Avery Lane")
            .identify(utterances: utterances, meURL: meURL, themURL: themURL, call: (id: "call-1", start: .distantPast), invite: invite)
    }

    /// The owner, an invited colleague at 800 Hz, and the brother of the voiceless invitee, close to the 400 Hz voice.
    func savedVoices() throws -> (VoiceSampleStore, PeopleStore) {
        let people = PeopleStore(directory: dir.appendingPathComponent("People"))
        let samples = VoiceSampleStore(directory: dir.appendingPathComponent("Voices"))
        library.identity = VoiceIdentity(people: people, samples: samples)
        try library.add([1, 0, 0, 0], to: "Avery Lane", isOwner: true)
        try library.add([0, 0, 0, 1], to: "Mira Stone")
        try library.setEmail("mira@example.com", for: "Mira Stone")
        try library.add([0.7, 0.71, 0, 0], to: "Dale Fenwick")
        return (samples, people)
    }

    func testTheUninvitedBrotherIsNotNamedAndTheVoicelessInviteeIs() async throws {
        let (samples, people) = try savedVoices()
        try writeSegments(meURL, total: 30, [(0, 5, 200)])
        try writeSegments(themURL, total: 30, [(6, 12, 800), (13, 20, 400)])
        let invite = CallInvite(guests: [CallInvite.Guest(name: "Mira Stone", email: "mira@example.com"),
                                         CallInvite.Guest(email: "jo.fenwick@example.com")])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 12), u(.them, "B", 13, 20)], invite: invite)
        XCTAssertEqual(result.names["me:A"], "Avery Lane")
        XCTAssertEqual(result.names["them:A"], "Mira Stone")
        XCTAssertEqual(result.names["them:B"], "Jo Fenwick")
        XCTAssertTrue(result.unknown.isEmpty)
        let jo = try XCTUnwrap(library.profiles.first { $0.name == "Jo Fenwick" })
        XCTAssertEqual(jo.embeddings, [[0, 1, 0, 0]])
        XCTAssertEqual(jo.email, "jo.fenwick@example.com")
        let id = try XCTUnwrap(people.id(forVoiceName: "Jo Fenwick"))
        XCTAssertEqual(samples.samples(of: id).map(\.origin), [.inviteInference])
        XCTAssertEqual(samples.samples(of: id).first?.callID, "call-1")
        XCTAssertEqual(library.profiles.first { $0.name == "Dale Fenwick" }?.embeddings.count, 1)
    }

    func testWithoutAnInviteTheBrotherIsNamedAsBefore() async throws {
        _ = try savedVoices()
        try writeSegments(meURL, total: 30, [(0, 5, 200)])
        try writeSegments(themURL, total: 30, [(13, 20, 400)])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "B", 13, 20)], invite: nil)
        XCTAssertEqual(result.names["them:B"], "Dale Fenwick")
    }

    func testTwoVoicelessInviteesLeaveTheVoiceToBeNamed() async throws {
        _ = try savedVoices()
        try writeSegments(meURL, total: 30, [(0, 5, 200)])
        try writeSegments(themURL, total: 30, [(13, 20, 400)])
        let invite = CallInvite(guests: [CallInvite.Guest(email: "jo.fenwick@example.com"), CallInvite.Guest(name: "Pat Quill")])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "B", 13, 20)], invite: invite)
        XCTAssertNil(result.names["them:B"])
        XCTAssertEqual(result.unknown, ["them:B"])
        XCTAssertEqual(library.profiles.map(\.name), ["Avery Lane", "Mira Stone", "Dale Fenwick"])
    }

    func testAStrongUninvitedMatchNamesButNeverTeaches() async throws {
        try library.add([0, 0.995, 0.1, 0], to: "Dale Fenwick")
        try library.add([0, 0, 0, 1], to: "Mira Stone")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 12, 400)])
        let result = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 12)], invite: CallInvite(guests: [CallInvite.Guest(name: "Mira Stone")]))
        XCTAssertEqual(result.names["them:A"], "Dale Fenwick")
        XCTAssertEqual(library.profiles.first { $0.name == "Dale Fenwick" }?.embeddings.count, 1)
    }

    func testAnInvitedSureMatchStillTeaches() async throws {
        try library.add([0, 0.995, 0.1, 0], to: "Dale Fenwick")
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [(6, 12, 400)])
        _ = try await identify([u(.me, "A", 0, 5), u(.them, "A", 6, 12)], invite: CallInvite(guests: [CallInvite.Guest(name: "Dale Fenwick")]))
        XCTAssertEqual(library.profiles.first { $0.name == "Dale Fenwick" }?.embeddings.count, 2)
    }

    func testTheOwnersVoiceIsNamedWhenTheInviteDoesNotListThem() async throws {
        try library.add([1, 0, 0, 0], to: "Avery Lane", isOwner: true)
        try writeSegments(meURL, total: 20, [(0, 5, 200)])
        try writeSegments(themURL, total: 20, [])
        let result = try await identify([u(.me, "A", 0, 5)], invite: CallInvite(guests: [CallInvite.Guest(name: "Mira Stone")]))
        XCTAssertEqual(result.names["me:A"], "Avery Lane")
        XCTAssertEqual(library.owner?.embeddings.count, 1)
    }
}
