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
        try await SpeakerIdentifier(library: library, provider: provider).identify(utterances: utterances, meURL: meURL, themURL: themURL)
    }

    func testOwnerEnrolledFromDominantMeSpeakerWhenLibraryHasNoOwner() async throws {
        try writeSegments(meURL, total: 30, [(0, 10, 200), (20, 23, 600)])
        try writeSegments(themURL, total: 30, [])
        let result = try await identify([u(.me, "A", 0, 10), u(.me, "B", 20, 23)])
        XCTAssertEqual(result.names["me:A"], "David Webber")
        XCTAssertEqual(library.owner?.name, "David Webber")
        XCTAssertEqual(result.unknown, ["me:B"])
    }

    func testOwnerIsNotEnrolledFromEchoOfTheOtherSide() async throws {
        // me:A is the other side leaking into the mic: it talks most, but only while them:A talks.
        try writeSegments(meURL, total: 60, [(0, 30, 600), (40, 50, 200)])
        try writeSegments(themURL, total: 60, [(0, 30, 400)])
        let result = try await identify([u(.me, "A", 0, 30), u(.them, "A", 0, 30), u(.me, "B", 40, 50)])
        XCTAssertEqual(result.names["me:B"], "David Webber")
        XCTAssertNotEqual(result.names["me:A"], "David Webber")
    }

    func testOwnerIsNotEnrolledFromSlightlyLateEcho() async throws {
        // David only listens; the echo on his mic is 0.1 s late.
        try writeSegments(meURL, total: 60, [(0.1, 30.1, 600)])
        try writeSegments(themURL, total: 60, [(0, 30, 400)])
        let result = try await identify([u(.me, "A", 0.1, 30.1), u(.them, "A", 0, 30)])
        XCTAssertNotEqual(result.names["me:A"], "David Webber")
        XCTAssertNil(library.owner)
    }

    func testOwnerIsNotEnrolledWhenMostOfTheSpeechIsEcho() async throws {
        // One mic label holds 60 s of echo and 6 s alone: the fingerprint would be mostly the other voice.
        try writeSegments(meURL, total: 80, [(0, 60, 600), (70, 76, 200)])
        try writeSegments(themURL, total: 80, [(0, 60, 400)])
        let result = try await identify([u(.me, "A", 0, 60), u(.them, "A", 0, 60), u(.me, "A", 70, 76)])
        XCTAssertNotEqual(result.names["me:A"], "David Webber")
        XCTAssertNil(library.owner)
    }

    func testOwnerMatchedByVoiceOnMeTrack() async throws {
        try library.add([1, 0, 0, 0], to: "David Webber", isOwner: true)
        try writeSegments(meURL, total: 30, [(0, 3, 600), (5, 20, 200)])
        try writeSegments(themURL, total: 30, [])
        let result = try await identify([u(.me, "A", 0, 3), u(.me, "B", 5, 20)])
        XCTAssertEqual(result.names["me:B"], "David Webber")
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
        try library.add([0, 1, 0, 0], to: "Alex Rivera")
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
}
