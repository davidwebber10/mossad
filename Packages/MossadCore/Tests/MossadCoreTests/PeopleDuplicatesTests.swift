import XCTest
@testable import MossadCore

final class PeopleDuplicatesTests: XCTestCase {
    var dir: URL!
    var library: VoiceLibrary!
    override func setUp() { dir = tempDirectory(); library = VoiceLibrary(directory: dir) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Naming a voice "james gregson", or with James's email, adds to James instead of making a second James.
    func testANameOrEmailFindsTheSavedPerson() throws {
        try library.add([1, 0, 0, 0], to: "James Gregson")
        try library.setEmail("jgregson@example.com", for: "James Gregson")
        XCTAssertEqual(library.existingName(name: "  james  gregson ", email: nil), "James Gregson")
        XCTAssertEqual(library.existingName(name: "Jim G", email: "JGregson@example.com"), "James Gregson")
        XCTAssertNil(library.existingName(name: "Jane Park", email: "jpark@example.com"))
    }

    func testFindsTheSameEmailTheSameNameASimilarNameAndTheSameVoice() throws {
        try library.add([1, 0, 0, 0], to: "Ben Spiegel")
        try library.setEmail("bspiegel@example.com", for: "Ben Spiegel")
        try library.setEmail("BSpiegel@example.com", for: "Ben S")
        try library.add([0, 1, 0, 0], to: "Zach Sampson")
        try library.add([0, 0, 1, 0], to: "Zach Samson")
        try library.add([0, 0, 0, 1], to: "Mia Long")
        try library.add([0.02, 0, 0, 1], to: "Speaker voice 2")
        try library.add([0, 0.7, 0.7, 0], to: "Ann Lee")
        let found = PeopleDuplicates.find(library.profiles)
        func reason(_ a: String, _ b: String) -> PeopleDuplicates.Reason? {
            found.first { Set([$0.first, $0.second]) == Set([a, b]) }?.reason
        }
        XCTAssertEqual(reason("Ben Spiegel", "Ben S"), .sameEmail)
        XCTAssertEqual(reason("Zach Sampson", "Zach Samson"), .similarName)
        XCTAssertEqual(reason("Mia Long", "Speaker voice 2"), .sameVoice)
        XCTAssertNil(reason("Ann Lee", "Mia Long"))
        XCTAssertEqual(found.count, 3)
    }

    func testTwoPeopleWithOneFirstNameAreNotDuplicates() throws {
        try library.add([1, 0, 0, 0], to: "Scott Miller")
        try library.add([0, 1, 0, 0], to: "Scott Taylor")
        XCTAssertTrue(PeopleDuplicates.find(library.profiles).isEmpty)
    }
}
