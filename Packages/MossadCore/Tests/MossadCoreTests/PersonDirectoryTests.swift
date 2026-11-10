import XCTest
@testable import MossadCore

/// A name or an email written in a meeting, matched to a saved person, so the meeting page can open their profile.
final class PersonDirectoryTests: XCTestCase {
    private let people = PersonDirectory([
        .init(name: "Sam Carter", email: "sam.carter@example.com"),
        .init(name: "Dana Lee", email: nil),
        .init(name: "Samuel Reed", email: "sreed@example.com"),
        .init(name: "Jo", email: nil),
    ])

    func testAnEmailFindsItsPersonInAnyCase() {
        XCTAssertEqual(people.person(for: "Sam.Carter@Example.com"), "Sam Carter")
        XCTAssertNil(people.person(for: "nobody@example.com"))
    }

    func testANameMatchesInAnyCaseAndSpacing() {
        XCTAssertEqual(people.person(for: "dana  lee"), "Dana Lee")
        XCTAssertEqual(people.person(for: " Jo "), "Jo")
    }

    func testAFirstNameAloneMatchesOnlyAmongTheMeetingsPeople() {
        XCTAssertNil(people.person(for: "Dana"), "a first name with no meeting around it can be anyone")
        XCTAssertEqual(people.person(for: "Dana", among: ["Dana Lee", "Sam Carter"]), "Dana Lee")
        XCTAssertEqual(people.person(for: "dana", among: ["Dana Lee"]), "Dana Lee")
    }

    func testAFirstNameThatFitsTwoPeopleOfTheMeetingMatchesNobody() {
        XCTAssertNil(people.person(for: "Sam", among: ["Sam Carter", "Samuel Reed"]))
        XCTAssertEqual(people.person(for: "Sam", among: ["Sam Carter", "Dana Lee"]), "Sam Carter")
    }

    func testANicknameMatchesTheLongForm() {
        XCTAssertEqual(people.person(for: "Sammy Reed"), nil, "not a short form this app knows")
        XCTAssertEqual(people.person(for: "Sam Reed"), "Samuel Reed")
        XCTAssertEqual(people.person(for: "Samuel Carter"), "Sam Carter")
        XCTAssertEqual(people.person(for: "Samuel", among: ["Sam Carter"]), "Sam Carter")
    }

    func testAnInitialStandsForTheLastName() {
        XCTAssertEqual(people.person(for: "Sam C."), "Sam Carter")
        XCTAssertEqual(people.person(for: "Dana L"), "Dana Lee")
        XCTAssertNil(people.person(for: "Dana K."))
    }

    func testAnUnnamedVoiceAndAnUnknownNameMatchNobody() {
        XCTAssertNil(people.person(for: "Speaker A", among: ["Speaker A"]))
        XCTAssertNil(people.person(for: "Riley Chen"))
        XCTAssertNil(people.person(for: ""))
        XCTAssertNil(PersonDirectory().person(for: "Sam Carter"))
    }

    func testTheDirectoryIsBuiltFromTheVoiceLibrary() {
        let d = PersonDirectory(profiles: [VoiceProfile(name: "Dana Lee", isOwner: true, embeddings: [], email: "dana@example.com")])
        XCTAssertEqual(d.person(for: "DANA@example.com"), "Dana Lee")
        XCTAssertEqual(d.people, [.init(name: "Dana Lee", email: "dana@example.com")])
    }
}
