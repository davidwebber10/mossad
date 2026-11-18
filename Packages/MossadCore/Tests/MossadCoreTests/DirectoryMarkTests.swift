import XCTest
@testable import MossadCore

/// "From your directory": the quiet mark on a person whom the Gemini people step made and the owner has not touched.
final class DirectoryMarkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func made(_ name: String = "Sam Carter", email: String = "sam.carter@example.com") -> Person {
        var p = Person(displayName: name, origin: .googleDirectory, at: t0)
        p.setVerifiedEmails([email], at: t0)
        return p
    }

    private let given: Set<String> = ["sam.carter@example.com", "scarter@example.com"]

    // MARK: The rule

    func testAPersonTheStepMadeShowsTheMark() {
        XCTAssertTrue(DirectoryMark.shows(made(), hasVoice: false, given: given))
    }

    func testAPersonFromAVoiceOrTheOwnerNeverShowsIt() {
        var voice = made()
        voice.origin = .voiceNaming
        XCTAssertFalse(DirectoryMark.shows(voice, hasVoice: false, given: given))
        var owner = made()
        owner.isOwner = true
        XCTAssertFalse(DirectoryMark.shows(owner, hasVoice: false, given: given))
    }

    func testAVoiceSampleTakesTheMarkAway() {
        XCTAssertFalse(DirectoryMark.shows(made(), hasVoice: true, given: given))
    }

    func testANameTheOwnerGaveTakesTheMarkAway() {
        var p = made()
        p.rename(to: "Samuel Carter", source: .owner, at: t0)
        XCTAssertFalse(DirectoryMark.shows(p, hasVoice: false, given: given))
    }

    func testAnAddressTheOwnerTypedTakesTheMarkAway() {
        var p = made()
        p.setVerifiedEmails(["sam.carter@example.com", "sam@home.example.com"], at: t0)
        XCTAssertFalse(DirectoryMark.shows(p, hasVoice: false, given: given))
    }

    func testAnotherAddressOfTheSameDirectoryPersonKeepsIt() {
        var p = made()
        p.setVerifiedEmails(["scarter@example.com"], at: t0)
        XCTAssertTrue(DirectoryMark.shows(p, hasVoice: false, given: given))
    }

    func testNoAddressLeftTakesTheMarkAway() {
        var p = made()
        p.setVerifiedEmails([], at: t0)
        XCTAssertFalse(DirectoryMark.shows(p, hasVoice: false, given: given))
    }

    func testNotTheirAddressTakesTheMarkAway() {
        var p = made()
        p.emails.append(EmailIdentity(address: "s.carter@example.com", state: .rejected, source: .owner, at: t0))
        XCTAssertFalse(DirectoryMark.shows(p, hasVoice: false, given: given))
    }

    // Unknown is not false: the step made the person, whatever the record of addresses says now.
    func testWithNoRecordOfGivenAddressesTheAddressesAreNotRead() {
        var p = made()
        p.setVerifiedEmails(["sam@home.example.com"], at: t0)
        XCTAssertTrue(DirectoryMark.shows(p, hasVoice: false, given: nil))
    }

    func testADeletedPersonOrARedirectNeverShowsIt() {
        var deleted = made()
        deleted.deleted = t0
        XCTAssertFalse(DirectoryMark.shows(deleted, hasVoice: false, given: given))
        var redirect = made()
        redirect.mergedInto = PersonID()
        XCTAssertFalse(DirectoryMark.shows(redirect, hasVoice: false, given: given))
    }

    // MARK: By the voice's name

    func testTheNamesFollowTheSurvivorOfAMerge() {
        let survivor = made()
        var absorbed = Person(displayName: "S. Carter", origin: .voiceNaming, at: t0)
        absorbed.mergedInto = survivor.id
        let profiles = [VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [], email: "sam.carter@example.com")]
        XCTAssertEqual(DirectoryMark.names(profiles: profiles, people: [survivor, absorbed], samples: [], given: given), ["Sam Carter"])
    }

    func testASampleOfThePersonOrAFingerprintOfTheVoiceTakesTheNameAway() {
        let p = made()
        let profile = VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [], email: "sam.carter@example.com")
        let sample = VoiceSample(personID: p.id, vector: [1, 0], source: VoiceSampleSource(callID: "x", origin: .ownerNamed), learned: t0)
        XCTAssertEqual(DirectoryMark.names(profiles: [profile], people: [p], samples: [sample], given: given), [])
        let heard = VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [[1, 0]], email: "sam.carter@example.com")
        XCTAssertEqual(DirectoryMark.names(profiles: [heard], people: [p], samples: [], given: given), [])
    }

    // MARK: With the real stores

    private func stores() -> (paths: Paths, library: VoiceLibrary, people: PeopleStore) {
        let paths = Paths(root: tempDirectory())
        let library = VoiceLibrary(directory: paths.voices)
        let people = PeopleStore(directory: paths.people)
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: paths.voices))
        return (paths, library, people)
    }

    private func marked(_ s: (paths: Paths, library: VoiceLibrary, people: PeopleStore)) -> Set<String> {
        DirectoryMark.names(profiles: s.library.profiles, people: s.people.people, samples: s.library.identity?.samples.samples ?? [],
                            given: GeminiPeopleBook.knownGiven(s.paths))
    }

    private func linked() -> (paths: Paths, library: VoiceLibrary, people: PeopleStore) {
        let s = stores()
        var r = CallRecord(id: "20261102-090000-notes", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.source = CallRecord.geminiNotesSource
        r.speakerNames = ["them:A": "Sam Carter"]
        r.invitees = [Invitee(name: nil, email: "sam.carter@example.com")]
        let directory = [GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", source: .directory)]
        GeminiPeople.link([r], library: s.library, people: s.people, directory: directory, paths: s.paths, domains: .none)
        return s
    }

    func testThePersonTheStepMakesShowsTheMark() {
        XCTAssertEqual(marked(linked()), ["Sam Carter"])
    }

    // A lost book is not "the step gave nothing": the origin is known, so the addresses are not read.
    func testAMissingBookFileIsNotReadAsNoAddressGiven() throws {
        let s = linked()
        try FileManager.default.removeItem(at: GeminiPeopleBook.url(s.paths))
        XCTAssertNil(GeminiPeopleBook.knownGiven(s.paths))
        XCTAssertEqual(marked(s), ["Sam Carter"])
    }

    func testTheOwnersRenameInTheStoresTakesTheMarkAway() throws {
        let s = linked()
        try s.library.rename("Sam Carter", to: "Samuel Carter")
        XCTAssertEqual(marked(s), [])
    }

    func testTheOwnersNewAddressInTheStoresTakesTheMarkAway() throws {
        let s = linked()
        try s.library.setEmail("sam@home.example.com", for: "Sam Carter")
        XCTAssertEqual(marked(s), [])
    }

    func testAVoiceLearnedInTheStoresTakesTheMarkAway() throws {
        let s = linked()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        XCTAssertEqual(marked(s), [])
    }
}
