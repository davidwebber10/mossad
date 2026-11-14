import XCTest
@testable import MossadCore

final class GeminiPeopleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let directory = ["sam.carter@example.com": "Sam Carter", "jordan.lee@example.com": "Jordan Lee",
                             "pat@example.com": "Pat Moreno", "pmoreno@example.com": "Pat Moreno",
                             "alex@example.com": "Alex Rivera"]

    private func notes(_ speakers: [String: String], _ invitees: [Invitee], id: String = "20261102-090000-notes") -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.source = CallRecord.geminiNotesSource
        r.speakerNames = speakers
        r.invitees = invitees
        return r
    }

    private func invited(_ email: String) -> Invitee { Invitee(name: nil, email: email) }

    private var meeting: CallRecord {
        notes(["me:A": "Alex Rivera", "them:A": "Sam Carter", "them:B": "Jordan Lee"],
              [Invitee(name: nil, email: "alex@example.com", isSelf: true), invited("sam.carter@example.com"), invited("jordan.lee@example.com")])
    }

    // MARK: Who matches

    func testASpeakerWhoseFullNameIsTheDirectoryNameOfOneInvitedAddressMatches() {
        XCTAssertEqual(Set(GeminiPeople.matches(meeting, directory: directory).map(\.email)), ["sam.carter@example.com", "jordan.lee@example.com"])
        XCTAssertEqual(GeminiPeople.matches(meeting, directory: directory).first { $0.email == "sam.carter@example.com" }?.name, "Sam Carter")
    }

    func testCaseAndSpacingDoNotMatter() {
        let r = notes(["them:A": "sam  carter"], [invited("sam.carter@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [GeminiPeople.Match(name: "Sam Carter", email: "sam.carter@example.com")])
    }

    func testTwoInvitedAddressesWithTheSameNameMatchNobody() {
        let r = notes(["them:A": "Pat Moreno"], [invited("pat@example.com"), invited("pmoreno@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    func testAFirstNameAloneMatchesNobody() {
        let r = notes(["them:A": "Sam"], [invited("sam.carter@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    func testAnAddressThatIsNotInvitedMatchesNobody() {
        let r = notes(["them:A": "Sam Carter"], [invited("jordan.lee@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    func testTheOwnerAndRoomsAreLeftOut() {
        var room = invited("sam.carter@example.com")
        room.kind = "room"
        let r = notes(["me:A": "Alex Rivera", "them:A": "Sam Carter"], [Invitee(name: nil, email: "alex@example.com", isSelf: true), room])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    func testOneAddressForTwoSpeakerLabelsIsOneMatch() {
        let r = notes(["them:A": "Sam Carter", "them:B": "Sam Carter"], [invited("sam.carter@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory).map(\.email), ["sam.carter@example.com"])
    }

    func testOnlyGeminiMeetings() {
        var r = meeting
        r.source = nil
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    func testTheDirectoryNamesLeaveOutContacts() {
        let cache = GoogleDirectoryCache(profiles: [GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", source: .directory),
                                                    GoogleProfile(emails: ["mom@example.com"], name: "Mom", source: .contacts)], read: t0)
        XCTAssertEqual(GeminiPeople.directoryNames(cache), ["sam.carter@example.com": "Sam Carter"])
    }

    func testAnInvitedAddressInMixedCaseMatches() {
        let r = notes(["them:A": "Sam Carter"], [invited(" Sam.Carter@Example.com ")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory).map(\.email), ["sam.carter@example.com"])
    }

    // MARK: Saved people

    func testAMatchBecomesAPersonWithTheAddressAndNoVoice() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        let out = GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertEqual(out.added, 2)
        XCTAssertEqual(out.done, [meeting.id])
        let sam = try XCTUnwrap(library.profiles.first { $0.name == "Sam Carter" })
        XCTAssertEqual(sam.emails, ["sam.carter@example.com"])
        XCTAssertTrue(sam.embeddings.isEmpty)
    }

    func testAPersonWithThatNameAndNoAddressGetsIt() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.add([0, 1, 0, 0], to: "Sam Carter")
        GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam.carter@example.com"])
        XCTAssertEqual(library.profiles.filter { $0.name == "Sam Carter" }.count, 1)
    }

    // The same name with another address can be another person: nothing is joined on a name alone.
    func testAPersonWithThatNameAndAnotherAddressIsLeftAlone() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.addEmail("sam@other.example.com", for: "Sam Carter")
        GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam@other.example.com"])
    }

    func testAnAddressThatSomeoneElseHasIsLeftAlone() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.addEmail("sam.carter@example.com", for: "Samuel Carter")
        GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertNil(library.profiles.first { $0.name == "Sam Carter" })
    }

    // A meeting is read once: a person the owner deleted afterwards does not come back.
    func testAMeetingThatWasDoneIsNotReadAgain() {
        let library = VoiceLibrary(directory: tempDirectory())
        let out = GeminiPeople.link([meeting], library: library, directory: directory, done: [meeting.id])
        XCTAssertEqual(out.added, 0)
        XCTAssertTrue(library.profiles.isEmpty)
    }

    // The directory spells the name; the transcript's spelling can differ in case and spacing.
    func testThePersonGetsTheDirectorysSpelling() {
        let library = VoiceLibrary(directory: tempDirectory())
        GeminiPeople.link([notes(["them:A": "sam  CARTER"], [invited("sam.carter@example.com")])], library: library, directory: directory, done: [])
        XCTAssertEqual(library.profiles.map(\.name), ["Sam Carter"])
    }

    func testAPersonWhoseNameDiffersOnlyInCaseAndHasNoAddressGetsIt() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.add([0, 1, 0, 0], to: "SAM CARTER")
        GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertEqual(library.profiles.filter { PersonNames.nameKey($0.name) == "sam carter" }.map(\.emails), [["sam.carter@example.com"]])
    }

    func testAPersonWhoseNameDiffersOnlyInCaseAndHasAnotherAddressIsLeftAlone() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.addEmail("sam@other.example.com", for: "sam carter")
        GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertEqual(library.profiles.filter { PersonNames.nameKey($0.name) == "sam carter" }.map(\.emails), [["sam@other.example.com"]])
    }

    // A saved person of the people store with that name and another address, with no voice profile of that name.
    func testASavedPersonWithAnotherAddressIsLeftAlone() {
        let library = VoiceLibrary(directory: tempDirectory())
        var sam = Person(displayName: "Sam Carter", isOwner: false, origin: .googleDirectory, at: t0)
        _ = sam.addEmail("sam@other.example.com", state: .seen, source: .googleDirectory, at: t0)
        GeminiPeople.link([meeting], library: library, directory: directory, done: [], people: [sam])
        XCTAssertNil(library.profiles.first { $0.name == "Sam Carter" })
    }

    // Without the directory nothing can match: the meetings wait for it.
    func testWithoutTheDirectoryNoMeetingIsDone() {
        let library = VoiceLibrary(directory: tempDirectory())
        let out = GeminiPeople.link([meeting], library: library, directory: [:], done: [])
        XCTAssertEqual(out.done, [])
    }

    // The owner deleted the person once: a later meeting does not make them again.
    func testAPersonTheOwnerDeletedIsNotMadeAgain() {
        let library = VoiceLibrary(directory: tempDirectory())
        var sam = Person(displayName: "Sam Carter", isOwner: false, origin: .googleDirectory, at: t0)
        sam.deleted = t0
        GeminiPeople.link([meeting], library: library, directory: directory, done: [], people: [sam])
        XCTAssertNil(library.profiles.first { $0.name == "Sam Carter" })
    }

    func testAPersonWhoHasTheAddressAndAnotherIsUnchanged() throws {
        let library = VoiceLibrary(directory: tempDirectory())
        try library.addEmail("sam.carter@example.com", for: "Sam Carter")
        try library.addEmail("sam@home.example.com", for: "Sam Carter")
        let out = GeminiPeople.link([meeting], library: library, directory: directory, done: [])
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam.carter@example.com", "sam@home.example.com"])
        XCTAssertTrue(out.done.contains(meeting.id))
    }
}

