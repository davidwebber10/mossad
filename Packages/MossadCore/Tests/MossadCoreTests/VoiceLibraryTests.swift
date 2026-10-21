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
        try VoiceLibrary(directory: dir).add([0, 0, 1], to: "David Webber", isOwner: true)
        let reloaded = VoiceLibrary(directory: dir)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["David Webber"])
        XCTAssertEqual(reloaded.owner?.name, "David Webber")
    }
}
