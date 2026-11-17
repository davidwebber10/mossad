import XCTest
@testable import MossadCore

final class GeminiPeopleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let directory = [GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", source: .directory),
                             GoogleProfile(emails: ["jordan.lee@example.com"], name: "Jordan Lee", source: .directory),
                             GoogleProfile(emails: ["pat@example.com"], name: "Pat Moreno", source: .directory),
                             GoogleProfile(emails: ["pmoreno@example.com"], name: "Pat Moreno", source: .directory),
                             GoogleProfile(emails: ["mstone@example.com"], name: "Michael Stone", source: .directory),
                             GoogleProfile(emails: ["reception@example.com"], name: "Front Desk", source: .directory),
                             GoogleProfile(emails: ["alex@example.com"], name: "Alex Rivera", source: .directory)]

    private func notes(_ speakers: [String: String], _ invitees: [Invitee], id: String = "20261102-090000-notes") -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.source = CallRecord.geminiNotesSource
        r.speakerNames = speakers
        r.invitees = invitees
        return r
    }

    private func invited(_ email: String, _ name: String? = nil) -> Invitee { Invitee(name: name, email: email) }

    private var meeting: CallRecord {
        notes(["me:A": "Alex Rivera", "them:A": "Sam Carter", "them:B": "Jordan Lee"],
              [Invitee(name: nil, email: "alex@example.com", isSelf: true), invited("sam.carter@example.com"), invited("jordan.lee@example.com")])
    }

    private func sam(id: String = "20261102-090000-notes") -> CallRecord {
        notes(["them:A": "Sam Carter"], [invited("sam.carter@example.com")], id: id)
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

    func testAContactIsNoMatchButItsNameCounts() {
        let mom = GoogleProfile(emails: ["mom@example.net"], name: "Mom Smith", source: .contacts)
        XCTAssertEqual(GeminiPeople.matches(notes(["them:A": "Mom Smith"], [invited("mom@example.net")]), directory: directory + [mom]), [])
        // An outside Sam Carter in the owner's contacts: the speaker can be either.
        let outside = GoogleProfile(emails: ["sam@acme.example"], name: "Sam Carter", source: .contacts)
        XCTAssertEqual(GeminiPeople.matches(sam(), directory: directory + [outside]), [])
        // The same person in the contacts is no other person.
        let same = GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", source: .contacts)
        XCTAssertEqual(GeminiPeople.matches(sam(), directory: directory + [same]).map(\.email), ["sam.carter@example.com"])
    }

    func testAnInvitedAddressInMixedCaseMatches() {
        let r = notes(["them:A": "Sam Carter"], [invited(" Sam.Carter@Example.com ")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory).map(\.email), ["sam.carter@example.com"])
    }

    // Finding 5: two directory people with one name, of whom only one is invited.
    func testTwoDirectoryPeopleWithTheNameMatchNobodyWhenOneIsInvited() {
        let r = notes(["them:A": "Pat Moreno"], [invited("pat@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    func testOneDirectoryPersonWithTwoAddressesIsOnePerson() {
        let two = [GoogleProfile(emails: ["sam.carter@example.com", "scarter@example.com"], name: "Sam Carter", source: .directory)]
        XCTAssertEqual(GeminiPeople.matches(sam(), directory: two).map(\.email), ["sam.carter@example.com"])
    }

    // Finding 5: another invited entry that can be someone of that name.
    func testAnotherInvitedEntryOfThatNameMatchesNobody() {
        let byName = notes(["them:A": "Sam Carter"], [invited("sam.carter@example.com"), invited("sc@acme.example", "Sam Carter")])
        XCTAssertEqual(GeminiPeople.matches(byName, directory: directory), [])
        let byAddress = notes(["them:A": "Sam Carter"], [invited("sam.carter@example.com"), invited("sam.carter@acme.example")])
        XCTAssertEqual(GeminiPeople.matches(byAddress, directory: directory), [])
    }

    // Finding 14: a role account is never a person.
    func testARoleAddressMatchesNobody() {
        let r = notes(["them:A": "Front Desk"], [invited("reception@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    // MARK: Saved people

    private struct Stores {
        let paths: Paths
        let library: VoiceLibrary
        let people: PeopleStore
    }

    private func stores() -> Stores {
        let paths = Paths(root: tempDirectory())
        let library = VoiceLibrary(directory: paths.voices)
        let people = PeopleStore(directory: paths.people)
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: paths.voices))
        return Stores(paths: paths, library: library, people: people)
    }

    @discardableResult
    private func link(_ s: Stores, _ records: [CallRecord], domains: CompanyDomains = .none, directory: [GoogleProfile]? = nil) -> GeminiPeople.Outcome {
        GeminiPeople.link(records, library: s.library, people: s.people, directory: directory ?? self.directory, paths: s.paths, domains: domains)
    }

    private func person(_ s: Stores, _ name: String) -> Person? { s.people.people.first { $0.isLive && $0.displayName == name } }

    func testAMatchBecomesAPersonWithTheAddressAndNoVoice() throws {
        let s = stores()
        let out = link(s, [meeting])
        XCTAssertEqual(out.made, 2)
        let sam = try XCTUnwrap(s.library.profiles.first { $0.name == "Sam Carter" })
        XCTAssertEqual(sam.emails, ["sam.carter@example.com"])
        XCTAssertTrue(sam.embeddings.isEmpty)
        XCTAssertEqual(person(s, "Sam Carter")?.emails.map(\.address), ["sam.carter@example.com"])
    }

    // Finding 6: the person says that Google's directory made it.
    func testTheNewPersonComesFromTheDirectory() throws {
        let s = stores()
        link(s, [sam()])
        XCTAssertEqual(try XCTUnwrap(person(s, "Sam Carter")).origin, .googleDirectory)
    }

    func testAPersonWithThatNameAndNoAddressGetsIt() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        let out = link(s, [meeting])
        XCTAssertEqual(out.joined, 1)
        XCTAssertEqual(s.library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam.carter@example.com"])
        XCTAssertEqual(s.library.profiles.filter { $0.name == "Sam Carter" }.count, 1)
        XCTAssertEqual(s.people.people.filter { $0.isLive && $0.displayName == "Sam Carter" }.count, 1)
    }

    // The same name with another address can be another person: nothing is joined on a name alone.
    func testAPersonWithThatNameAndAnotherAddressIsLeftAlone() throws {
        let s = stores()
        _ = try s.library.addEmail("sam@other.example.com", for: "Sam Carter")
        link(s, [meeting])
        XCTAssertEqual(s.library.profiles.filter { $0.name == "Sam Carter" }.map(\.emails), [["sam@other.example.com"]])
    }

    func testAnAddressThatSomeoneElseHasIsLeftAlone() throws {
        let s = stores()
        _ = try s.library.addEmail("sam.carter@example.com", for: "Samuel Carter")
        link(s, [meeting])
        XCTAssertNil(s.library.profiles.first { $0.name == "Sam Carter" })
    }

    func testThePersonGetsTheDirectorysSpelling() {
        let s = stores()
        link(s, [notes(["them:A": "sam  CARTER"], [invited("sam.carter@example.com")])])
        XCTAssertEqual(s.library.profiles.map(\.name), ["Sam Carter"])
    }

    func testAPersonWhoHasTheAddressAndAnotherIsUnchanged() throws {
        let s = stores()
        _ = try s.library.addEmail("sam.carter@example.com", for: "Sam Carter")
        _ = try s.library.addEmail("sam@home.example.com", for: "Sam Carter")
        let out = link(s, [meeting])
        XCTAssertEqual(out.joined, 0)
        XCTAssertEqual(s.library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam.carter@example.com", "sam@home.example.com"])
    }

    // Finding 1: "Not their address" holds against the directory and the next launch.
    func testAnAddressTheOwnerRejectedDoesNotComeBack() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        _ = try s.library.addEmail("sam.carter@example.com", for: "Sam Carter")
        // What the person page's "Not their address" does.
        try s.library.removeEmail("sam.carter@example.com", for: "Sam Carter")
        try s.people.rejectEmail("sam.carter@example.com", for: XCTUnwrap(s.people.id(forVoiceName: "Sam Carter")))
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.first { $0.name == "Sam Carter" }?.emails, [])
        XCTAssertEqual(person(s, "Sam Carter")?.emails.map(\.state), [.rejected])
        XCTAssertEqual(s.library.profiles.count, 1, "no new person with the address the owner refused")
    }

    // Finding 2: a part in brackets is the owner's way to name another person.
    func testANameWithBracketsIsAnotherPerson() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter (Acme)")
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.first { $0.name == "Sam Carter (Acme)" }?.emails, [])
        XCTAssertEqual(s.library.profiles.count, 1)
    }

    // Finding 2: two saved people who fit the name are nobody.
    func testTwoSavedPeopleWhoFitAreNobody() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        try s.library.add([1, 0, 0, 0], to: "SAM CARTER")
        let out = link(s, [sam()])
        XCTAssertEqual(out.made + out.joined, 0)
        XCTAssertEqual(s.library.profiles.map(\.emails), [[], []])
    }

    // Finding 3: a person the owner deleted is not made again by a later meeting.
    func testAPersonTheOwnerDeletedIsNotMadeAgain() throws {
        let s = stores()
        link(s, [sam(id: "20261102-090000-notes")])
        try s.library.delete("Sam Carter")
        XCTAssertNil(person(s, "Sam Carter"))
        let out = link(s, [sam(id: "20261109-090000-notes")])
        XCTAssertEqual(out.made, 0)
        XCTAssertNil(s.library.profiles.first { $0.name == "Sam Carter" })
        XCTAssertNil(person(s, "Sam Carter"))
    }

    // Finding 3: an address the owner took off a person is not given again.
    func testAnAddressGivenOnceIsNotGivenAgain() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        link(s, [sam()])
        try s.library.removeEmail("sam.carter@example.com", for: "Sam Carter")
        link(s, [sam(id: "20261109-090000-notes")])
        XCTAssertEqual(s.library.profiles.first { $0.name == "Sam Carter" }?.emails, [])
    }

    // Finding 3: the record is a file of the profile's data folder; one that cannot be read stops the step.
    func testAnUnreadableRecordStopsTheStep() throws {
        let s = stores()
        let url = GeminiPeopleBook.url(s.paths)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: url)
        let out = link(s, [sam()])
        XCTAssertEqual(out.made, 0)
        XCTAssertTrue(s.library.profiles.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("nope".utf8))
    }

    func testTheRecordIsInTheDataFolder() throws {
        let s = stores()
        link(s, [sam()])
        XCTAssertTrue(GeminiPeopleBook.url(s.paths).path.hasPrefix(s.paths.root.path))
        XCTAssertEqual(GeminiPeopleBook.load(s.paths)?.given, ["sam.carter@example.com"])
    }

    // Finding 4: a nickname form of a saved voice is a guess: no double.
    func testANicknameFormMakesNobody() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Mike Stone")
        link(s, [notes(["them:A": "Michael Stone"], [invited("mstone@example.com")])])
        XCTAssertEqual(s.library.profiles.map(\.name), ["Mike Stone"])
        XCTAssertEqual(s.library.profiles.first?.emails, [])
    }

    // Finding 4: a person the owner renamed keeps the old name as a form.
    func testARenamedPersonGetsNoDouble() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        try s.library.rename("Sam Carter", to: "Samantha Carter-Reed")
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.map(\.name), ["Samantha Carter-Reed"])
        XCTAssertEqual(s.library.profiles.first?.emails, [])
    }

    // Finding 4: a middle name on one side is a guess.
    func testAMiddleNameOnOneSideMakesNobody() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam A. Carter")
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.map(\.name), ["Sam A. Carter"])
        XCTAssertEqual(s.library.profiles.first?.emails, [], "the saved person gets no address")
    }

    // Finding 4: the address on another company domain is the saved person's.
    func testAnAddressOnAnotherCompanyDomainMakesNobody() throws {
        let s = stores()
        // A name that does not fit: only the address rule can hold the match back.
        try s.library.add([0, 1, 0, 0], to: "Riley Chen")
        _ = try s.library.addEmail("sam.carter@example.org", for: "Riley Chen")
        link(s, [sam()], domains: CompanyDomains(["example.com", "example.org"]))
        XCTAssertEqual(s.library.profiles.map(\.name), ["Riley Chen"])
        XCTAssertEqual(s.library.profiles.first?.emails, ["sam.carter@example.org"])
    }

    // Finding 7: a meeting left alone for a reason the owner can remove is read again.
    func testAMeetingLeftAloneIsReadAgainLater() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        _ = try s.library.addEmail("sam@other.example.com", for: "Sam Carter")
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.first?.emails, ["sam@other.example.com"])
        try s.library.removeEmail("sam@other.example.com", for: "Sam Carter")
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.first?.emails, ["sam.carter@example.com"])
    }

    // Without the directory nothing can match.
    func testWithoutTheDirectoryNothingIsDone() {
        let s = stores()
        XCTAssertEqual(link(s, [meeting], directory: []).made, 0)
        XCTAssertTrue(s.library.profiles.isEmpty)
    }

    // Finding 12: a call that starts stops the step.
    func testACallStopsTheStep() {
        let s = stores()
        let out = GeminiPeople.link([meeting], library: s.library, people: s.people, directory: directory, paths: s.paths, domains: .none, stop: { true })
        XCTAssertTrue(out.stopped)
        XCTAssertTrue(s.library.profiles.isEmpty)
    }

    // Finding 13: the owner is never made or changed.
    func testTheOwnerIsNeverChanged() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter", isOwner: true)
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.map(\.emails), [[]])
        XCTAssertEqual(s.people.people.filter(\.isLive).count, 1)
    }

    // MARK: The second review

    private func saveDirectory(_ s: Stores, _ profiles: [GoogleProfile]) throws {
        try GoogleDirectoryCache(profiles: profiles, read: t0).save(s.paths)
    }

    // A: a person whom the step did not make stays gone after the owner deletes them.
    func testADeletedPersonThatTheStepDidNotMakeStaysGone() throws {
        let s = stores()
        try saveDirectory(s, directory)
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        _ = try s.library.addEmail("sam.carter@example.com", for: "Sam Carter")
        // What the delete on the People page does.
        try GeminiPeopleBook.refuse(personNamed: "Sam Carter", library: s.library, paths: s.paths)
        try s.library.delete("Sam Carter")
        let out = link(s, [sam()])
        XCTAssertEqual(out.made, 0)
        XCTAssertTrue(s.library.profiles.isEmpty)
        XCTAssertNil(person(s, "Sam Carter"))
    }

    // A: the directory's other addresses of that name are refused too.
    func testADeleteRefusesTheDirectorysAddressesOfThatName() throws {
        let s = stores()
        try saveDirectory(s, directory)
        _ = try s.library.addEmail("sam@home.example.com", for: "Sam Carter")
        try GeminiPeopleBook.refuse(personNamed: "Sam Carter", library: s.library, paths: s.paths)
        try s.library.delete("Sam Carter")
        link(s, [sam()])
        XCTAssertTrue(s.library.profiles.isEmpty)
    }

    // A: the step records each address of the directory person, so a second address does not make them again.
    func testEveryAddressOfTheDirectoryPersonIsGivenOnce() throws {
        let s = stores()
        let two = [GoogleProfile(emails: ["sam.carter@example.com", "scarter@example.com"], name: "Sam Carter", source: .directory)]
        link(s, [sam()], directory: two)
        try s.library.delete("Sam Carter")
        let second = notes(["them:A": "Sam Carter"], [invited("scarter@example.com")], id: "20261109-090000-notes")
        XCTAssertEqual(link(s, [second], directory: two).made, 0)
        XCTAssertTrue(s.library.profiles.isEmpty)
    }

    // F: a plain "Remove" of an address that the owner typed holds too.
    func testARemovedAddressThatTheStepDidNotGiveDoesNotComeBack() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Sam Carter")
        _ = try s.library.addEmail("sam.carter@example.com", for: "Sam Carter")
        // What "Remove" on the person page does.
        try GeminiPeopleBook.refuse(["sam.carter@example.com"], paths: s.paths)
        try s.library.removeEmail("sam.carter@example.com", for: "Sam Carter")
        link(s, [sam()])
        XCTAssertEqual(s.library.profiles.first?.emails, [])
    }

    // B: a call that starts while the meetings are read ends the run before any write.
    func testACallInTheMatchPhaseEndsTheRun() {
        let s = stores()
        var calls = 0
        let records = [sam(id: "20261102-090000-notes"), notes(["them:A": "Jordan Lee"], [invited("jordan.lee@example.com")], id: "20261103-090000-notes")]
        let out = GeminiPeople.link(records, library: s.library, people: s.people, directory: directory, paths: s.paths, domains: .none,
                                    stop: { calls += 1; return calls > 1 })
        XCTAssertTrue(out.stopped)
        XCTAssertEqual(out.made, 0)
        XCTAssertTrue(s.library.profiles.isEmpty)
    }

    // E: an address that a quit left pending, and that nobody holds, is given again.
    func testAPendingAddressThatNobodyHoldsIsGivenAgain() throws {
        let s = stores()
        let url = GeminiPeopleBook.url(s.paths)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"given":["sam.carter@example.com"],"pending":["sam.carter@example.com"]}"#.utf8).write(to: url)
        XCTAssertEqual(link(s, [sam()]).made, 1)
        XCTAssertEqual(GeminiPeopleBook.load(s.paths)?.pending, nil)
        XCTAssertEqual(GeminiPeopleBook.load(s.paths)?.given, ["sam.carter@example.com"])
    }

    func testAPendingAddressThatSomeoneHoldsStaysGiven() throws {
        let s = stores()
        _ = try s.library.addEmail("sam.carter@example.com", for: "Samuel Carter")
        try GeminiPeopleBook(given: ["sam.carter@example.com"], pending: ["sam.carter@example.com"]).save(s.paths)
        link(s, [sam()])
        XCTAssertEqual(GeminiPeopleBook.load(s.paths)?.given, ["sam.carter@example.com"])
    }

    // An older book with no pending field still reads.
    func testAnOlderBookStillReads() throws {
        let s = stores()
        let url = GeminiPeopleBook.url(s.paths)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"given":["x@example.com"]}"#.utf8).write(to: url)
        XCTAssertEqual(GeminiPeopleBook.load(s.paths)?.given, ["x@example.com"])
    }

    // G: a speaker name with a part in brackets is another person than the directory's.
    func testASpeakerNameWithBracketsIsNotTheDirectoryPerson() {
        let r = notes(["them:A": "Sam Carter (Acme)"], [invited("sam.carter@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: directory), [])
    }

    // H: a people store that cannot be written stops the step, so voices.json and people.json never disagree.
    func testAStoreThatCannotBeWrittenStopsTheStep() throws {
        let paths = Paths(root: tempDirectory())
        try PeopleStore(directory: paths.people).ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        let file = paths.people.appendingPathComponent(PeopleStore.fileName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let store = PeopleStore(directory: paths.people)
        XCTAssertTrue(store.isReadOnly)
        let library = VoiceLibrary(directory: paths.voices)
        library.identity = VoiceIdentity(people: store, samples: VoiceSampleStore(directory: paths.voices))
        try library.add([0, 1, 0, 0], to: "Sam Carter")
        let out = GeminiPeople.link([sam()], library: library, people: store, directory: directory, paths: paths, domains: .none)
        XCTAssertEqual(out.joined + out.made, 0)
        XCTAssertEqual(library.profiles.first?.emails, [])
    }

    // K: an address of the owner is never a match, also when the invite does not mark it as the owner's.
    func testAnAddressOfTheOwnerIsNoMatch() {
        let owner = [GoogleProfile(emails: ["avery.webb@example.com"], name: "Avery Webb", source: .directory)]
        let r = notes(["them:A": "Avery Webb"], [invited("avery.webb@example.com")])
        XCTAssertEqual(GeminiPeople.matches(r, directory: owner, isOwner: { $0 == "avery.webb@example.com" }), [])
        XCTAssertEqual(GeminiPeople.matches(r, directory: owner).map(\.email), ["avery.webb@example.com"])
    }

    // K: in a run, the owner's addresses come from the owner's person, the owner's voice, and the owner's names.
    func testTheOwnersAddressesForARun() throws {
        let s = stores()
        try s.library.add([0, 1, 0, 0], to: "Avery Webb", isOwner: true)
        _ = try s.library.addEmail("avery@home.example.net", for: "Avery Webb")
        let isOwner = GeminiPeople.ownerAddresses(people: s.people.people, profiles: s.library.profiles)
        XCTAssertTrue(isOwner("avery@home.example.net"), "the owner's own address")
        XCTAssertTrue(isOwner("awebb@example.com"), "an address of the owner's name")
        XCTAssertFalse(isOwner("sam.carter@example.com"))
    }
}
