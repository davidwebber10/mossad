import XCTest
@testable import MossadCore

/// A name or an email written in a meeting, and the saved person it stands for. `link` decides what a click
/// opens, and takes only a sure match. `match` decides who an invited person is, and may use a short name.
final class PersonDirectoryTests: XCTestCase {
    private let people = PersonDirectory([
        .init(name: "Sam Carter", email: "sam.carter@example.com"),
        .init(name: "Dana Lee", email: nil),
        .init(name: "Samuel Reed", email: "sreed@example.com"),
        .init(name: "Jo", email: nil),
    ])

    // MARK: Links

    func testALinkTakesAnEmailOfASavedPerson() {
        XCTAssertEqual(people.link(for: "Sam.Carter@Example.com"), "Sam Carter")
        XCTAssertNil(people.link(for: "nobody@example.com"))
    }

    func testALinkTakesTheWholeNameInAnyCaseAndSpacing() {
        XCTAssertEqual(people.link(for: "dana  lee"), "Dana Lee")
        XCTAssertEqual(people.link(for: " Jo "), "Jo")
        XCTAssertNil(people.link(for: "Riley Chen"))
        XCTAssertNil(people.link(for: "Speaker A"))
        XCTAssertNil(people.link(for: ""))
        XCTAssertNil(PersonDirectory().link(for: "Sam Carter"))
    }

    func testALinkNeverTakesAFirstNameAShortFormOrAnInitial() {
        let meeting = ["Sam Carter", "Dana Lee"]
        XCTAssertNil(people.link(for: "Sam", in: meeting), "the one Sam of the meeting is still a guess")
        XCTAssertNil(people.link(for: "Dana", in: meeting))
        XCTAssertNil(people.link(for: "Sam C.", in: meeting))
        XCTAssertNil(people.link(for: "Sam Reed"), "Samuel Reed is saved, but this is not his name as saved")
        XCTAssertNil(people.link(for: "Samuel Carter", in: meeting))
    }

    func testASavedFirstNameDoesNotLinkWhenTheMeetingHasAnotherPersonWithIt() {
        // Review case 1: "Sam" and "Sam Carter" are both saved; the meeting's Sam is Sam Carter.
        let both = PersonDirectory([.init(name: "Sam", email: nil), .init(name: "Sam Carter", email: nil)])
        XCTAssertNil(both.link(for: "Sam", in: ["Sam Carter", "Dana Lee"]))
        XCTAssertEqual(both.link(for: "Sam Carter", in: ["Sam Carter", "Dana Lee"]), "Sam Carter")
        XCTAssertEqual(both.link(for: "Sam", in: ["Sam", "Dana Lee"]), "Sam", "the person saved as Sam, in a meeting with no other Sam")
        // Also a person who is not saved makes the one word unsure.
        XCTAssertNil(people.link(for: "Jo", in: ["Jo Park", "Dana Lee"]))
    }

    func testAFirstNameWithAnUnsavedPersonOfThatNameInTheMeetingLinksNobody() {
        // Review case 2: Sam Carter is saved and spoke; Sam Lee is invited and not saved.
        XCTAssertNil(people.link(for: "Sam", in: ["Sam Carter", "Sam Lee"]))
        XCTAssertNil(people.match("Sam", among: ["Sam Carter", "Sam Lee"]), "and nobody can say which Sam it is")
    }

    func testTwoFullNamesWithOneShortFormAreTwoPeople() {
        // Review case 3.
        let d = PersonDirectory([.init(name: "Alexandra Smith", email: nil), .init(name: "Samantha Reed", email: nil), .init(name: "Edward Jones", email: nil)])
        for (text, other) in [("Alexander Smith", "Alexandra Smith"), ("Samuel Reed", "Samantha Reed"), ("Theodore Jones", "Edward Jones")] {
            XCTAssertNil(d.link(for: text, in: [other]), text)
            XCTAssertNil(d.match(text, among: [other]), text)
        }
        XCTAssertEqual(d.match("Sam Reed", among: ["Samantha Reed"]), "Samantha Reed", "a short form with its full name")
        XCTAssertEqual(d.match("Ted Jones", among: ["Edward Jones"]), "Edward Jones")
        XCTAssertNil(d.link(for: "Sam Reed", in: ["Samantha Reed"]), "good enough to say who was invited, not to open a profile")
    }

    func testTwoSavedPeopleWithOneNameLinkNobody() {
        let d = PersonDirectory([.init(name: "Sam Carter", email: "a@example.com"), .init(name: "sam carter", email: "b@example.com")])
        XCTAssertNil(d.link(for: "Sam Carter"))
        XCTAssertEqual(d.link(for: "b@example.com"), "sam carter", "the email still says which one")
    }

    // MARK: Matching invited people

    func testAMatchTakesAShortNameOnlyAmongTheMeetingsPeople() {
        XCTAssertNil(people.match("Dana"), "a first name with no meeting around it can be anyone")
        XCTAssertEqual(people.match("Dana", among: ["Dana Lee", "Sam Carter"]), "Dana Lee")
        XCTAssertEqual(people.match("Sam C.", among: ["Sam Carter"]), "Sam Carter")
        XCTAssertEqual(people.match("Samuel Carter", among: ["Sam Carter"]), "Sam Carter")
        XCTAssertNil(people.match("Sam Reed"), "a short form needs the meeting too")
        XCTAssertEqual(people.match("Sam Reed", among: ["Samuel Reed"]), "Samuel Reed")
        XCTAssertNil(people.match("Sam", among: ["Sam Carter", "Samuel Reed"]), "two fit")
        XCTAssertNil(people.match("Dana K.", among: ["Dana Lee"]))
        XCTAssertNil(people.match("Riley", among: ["Riley Chen"]), "Riley Chen is in the meeting, but is not a saved person")
        XCTAssertEqual(people.match("sam.carter@example.com"), "Sam Carter")
        XCTAssertEqual(people.match("dana lee"), "Dana Lee")
        XCTAssertNil(people.match("Speaker A", among: ["Speaker A"]))
    }

    func testTheDirectoryIsBuiltFromTheVoiceLibrary() {
        let d = PersonDirectory(profiles: [VoiceProfile(name: "Dana Lee", isOwner: true, embeddings: [], email: "dana@example.com")])
        XCTAssertEqual(d.link(for: "DANA@example.com"), "Dana Lee")
        XCTAssertEqual(d.people, [.init(name: "Dana Lee", email: "dana@example.com")])
    }
}
