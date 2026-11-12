import XCTest
@testable import MossadCore

/// A person with more than one address, and the company's domains: every address of a person finds them, an
/// address is one person's only, and an address on another domain of the company is the same person when only one
/// person has that name before the @.
final class PersonEmailsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let domains = CompanyDomains.parse("acme.test, acmeinc.test\nACMEOUTDOOR.test")

    private func person(_ id: String, _ name: String, _ emails: [String], state: IdentityState = .verified) -> Person {
        var p = Person(id: PersonID(rawValue: id), displayName: name, origin: .voiceNaming, at: t0)
        for e in emails { p.addEmail(e, state: state, source: .owner, at: t0) }
        return p
    }

    // MARK: Company domains

    func testTheListIsReadFromWhatTheOwnerTyped() {
        XCTAssertEqual(domains.domains, ["acme.test", "acmeinc.test", "acmeoutdoor.test"])
        XCTAssertEqual(CompanyDomains.parse("@acme.test; acme.test,  not a domain, x").domains, ["acme.test"])
        XCTAssertEqual(domains.text, "acme.test, acmeinc.test, acmeoutdoor.test")
        XCTAssertTrue(domains.contains("Sam.Carter@ACMEINC.test"))
        XCTAssertFalse(domains.contains("sam@other.test"))
    }

    func testAnAddressOnAnotherListedDomainIsTheOnePersonWithThatLocalPart() {
        let sam = person("sam", "Sam Carter", ["sam.carter@acme.test"])
        let riley = person("riley", "Riley Park", ["riley@acme.test"])
        let resolver = PersonResolver(people: [sam, riley], domains: domains)
        let answer = resolver.resolve(PersonObservation(email: "Sam.Carter@acmeinc.test"))
        XCTAssertEqual(answer.person, PersonID(rawValue: "sam"))
        XCTAssertEqual(answer.rule, .companyEmail)
        XCTAssertNil(resolver.resolve(PersonObservation(email: "sam.carter@vendor.test")).person, "a domain that is not listed is nobody")
        XCTAssertNil(PersonResolver(people: [sam, riley]).resolve(PersonObservation(email: "sam.carter@acmeinc.test")).person,
                     "with no domains listed, nothing is joined")
    }

    func testTwoPeopleWithOneLocalPartAreNobody() {
        let sam = person("sam", "Sam Carter", ["sam@acme.test"])
        let other = person("sam2", "Sam Reed", ["sam@acmeoutdoor.test"])
        let resolver = PersonResolver(people: [sam, other], domains: domains)
        XCTAssertNil(resolver.resolve(PersonObservation(email: "sam@acmeinc.test")).person)
        XCTAssertEqual(resolver.resolve(PersonObservation(email: "sam@acme.test")).person, PersonID(rawValue: "sam"), "the exact address still wins")
    }

    func testARejectedAddressIsNeverJoinedByItsDomain() {
        var sam = person("sam", "Sam Carter", ["sam@acme.test"])
        sam.addEmail("sam@acmeinc.test", state: .rejected, source: .owner, at: t0)
        XCTAssertNil(PersonResolver(people: [sam], domains: domains).resolve(PersonObservation(email: "sam@acmeinc.test")).person)
    }

    // MARK: Every address of a person

    func testTheDirectoryLinksEveryAddressOfAPerson() {
        let directory = PersonDirectory([.init(name: "Sam Carter", emails: ["sam@acme.test", "sam@acmeinc.test"]), .init(name: "Riley Park", email: nil)])
        XCTAssertEqual(directory.link(for: "sam@acmeinc.test"), "Sam Carter")
        XCTAssertEqual(directory.link(for: "sam@acme.test"), "Sam Carter")
        XCTAssertEqual(directory.existing(name: "S. C.", email: "SAM@acmeinc.test"), "Sam Carter")
        XCTAssertEqual(PersonDirectory.Person(name: "Sam Carter", emails: ["sam@acme.test", "sam@acmeinc.test"]).email, "sam@acme.test")
    }

    func testTheDirectoryUsesTheCompanyDomains() {
        let directory = PersonDirectory([.init(name: "Sam Carter", email: "sam.carter@acme.test")], domains: domains)
        XCTAssertEqual(directory.link(for: "sam.carter@acmeoutdoor.test"), "Sam Carter")
        XCTAssertNotEqual(directory, PersonDirectory([.init(name: "Sam Carter", email: "sam@acme.test")]), "other domains, other answers")
    }

    func testTheDirectoryFromTheVoiceLibraryTakesThePeopleStoresAddressesToo() {
        let profiles = [VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [], email: "sam@acme.test")]
        let saved = [person("sam", "Sam Carter", ["sam@acme.test", "carter@acmeinc.test"])]
        let directory = PersonDirectory(profiles: profiles, people: saved)
        XCTAssertEqual(directory.link(for: "carter@acmeinc.test"), "Sam Carter")
    }

    func testTheMeetingFilterFindsAPersonByASecondAddress() {
        let people = MeetingFilterPeople(directory: PersonDirectory([.init(name: "Sam Carter", emails: ["sam@acme.test", "sam@acmeinc.test"])]),
                                         ids: ["Sam Carter": "id-sam"], owner: "Dana Lee")
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.attendees = ["sam@acmeinc.test"]
        XCTAssertEqual(MeetingFilterRow(record: r, people: people, rating: nil)?.people.map(\.id), ["id-sam"])
    }

    func testReferencesGiveTheIdOnASecondAddress() {
        let sam = person("sam", "Sam Carter", ["sam@acme.test", "sam@acmeinc.test"])
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.invitees = [Invitee(name: nil, email: "sam@acmeinc.test")]
        r.attendees = ["sam@acmeinc.test"]
        let refs = PersonReferences(people: [sam])
        XCTAssertEqual(refs.refresh(r).invitees?.first?.personID, "sam")
    }

    // MARK: The voice library

    func testAProfileFromAnOlderFileStillReadsAndKeepsItsFirstAddress() throws {
        let old = #"[{"name":"Sam Carter","isOwner":false,"embeddings":[],"email":"sam@acme.test"}]"#
        let profiles = try JSONDecoder().decode([VoiceProfile].self, from: Data(old.utf8))
        XCTAssertEqual(profiles[0].emails, ["sam@acme.test"])
        var p = profiles[0]
        p.moreEmails = ["sam@acmeinc.test"]
        let back = try JSONDecoder().decode([OlderProfile].self, from: JSONEncoder().encode([p]))
        XCTAssertEqual(back[0].email, "sam@acme.test", "an older reader still reads the first address")
    }

    private struct OlderProfile: Decodable { var name: String; var email: String? }

    func testAnAddressBelongsToOnePersonOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = VoiceLibrary(directory: dir)
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        try library.setEmail("riley@acme.test", for: "Riley Park")
        XCTAssertEqual(try library.addEmail("SAM@acmeinc.test", for: "Sam Carter"), .added)
        XCTAssertEqual(try library.addEmail("sam@acmeinc.test", for: "Sam Carter"), .alreadyTheirs)
        XCTAssertEqual(try library.addEmail("sam@acmeinc.test", for: "Riley Park"), .belongsTo("Sam Carter"), "never a silent move")
        XCTAssertEqual(library.profiles.first { $0.name == "Riley Park" }?.emails, ["riley@acme.test"])
        XCTAssertEqual(library.name(forEmail: "sam@acmeinc.test"), "Sam Carter")
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam@acme.test", "sam@acmeinc.test"])

        try library.removeEmail("sam@acme.test", for: "Sam Carter")
        let sam = library.profiles.first { $0.name == "Sam Carter" }
        XCTAssertEqual(sam?.email, "sam@acmeinc.test", "the next address becomes the first one")
        XCTAssertEqual(sam?.emails, ["sam@acmeinc.test"])

        try library.merge("Riley Park", into: "Sam Carter")
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam@acmeinc.test", "riley@acme.test"], "a merge keeps every address")
    }

    func testThePeopleStoreFollowsTheLibrarysAddresses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = VoiceLibrary(directory: dir)
        let identity = VoiceIdentity(people: PeopleStore(directory: dir), samples: VoiceSampleStore(directory: dir))
        library.identity = identity
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        _ = try library.addEmail("sam@acmeinc.test", for: "Sam Carter")
        let id = try XCTUnwrap(identity.people.id(forVoiceName: "Sam Carter"))
        XCTAssertEqual(identity.people.person(id)?.emails.filter { $0.state == .verified }.map(\.address), ["sam@acme.test", "sam@acmeinc.test"])
        try library.removeEmail("sam@acme.test", for: "Sam Carter")
        XCTAssertEqual(identity.people.person(id)?.emails.filter { $0.state == .verified }.map(\.address), ["sam@acmeinc.test"])
    }

    func testAnAddressThatAnotherSavedPersonHasIsTheirs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = VoiceLibrary(directory: dir)
        let store = PeopleStore(directory: dir)
        library.identity = VoiceIdentity(people: store, samples: VoiceSampleStore(directory: dir))
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        // Someone the calendar saved, with no voice.
        let jo = try store.ensure(voiceName: "Jo Quinn", isOwner: false, origin: .calendar)
        try store.setEmail("jo@acmeinc.test", for: jo)
        XCTAssertEqual(try library.addEmail("jo@acmeinc.test", for: "Sam Carter"), .belongsTo("Jo Quinn"))
    }

    // MARK: Google's directory

    func testTheDirectoryAddsAPersonsAliasAddresses() {
        let sam = person("sam", "Sam Carter", ["sam@acme.test"])
        let jo = person("jo", "Jo Quinn", ["jo@acme.test"])
        let profile = GoogleProfile(emails: ["sam@acme.test", "sam@acmeinc.test", "jo@acme.test"], name: "Sam Carter", source: .directory)
        let alias = GoogleProfile(emails: ["riley@acme.test", "rp@acmeinc.test"], name: "Riley Park", source: .directory)
        let riley = person("riley", "Riley Park", ["riley@acme.test"])
        let out = DirectoryMerge.apply([profile, alias], to: [sam, jo, riley], at: t0).people
        XCTAssertEqual(out.first { $0.id.rawValue == "sam" }?.emails.map(\.address), ["sam@acme.test"],
                       "a profile that has another person's address gives no aliases")
        let r = out.first { $0.id.rawValue == "riley" }
        XCTAssertEqual(r?.emails.map(\.address), ["riley@acme.test", "rp@acmeinc.test"])
        XCTAssertEqual(r?.emails.last?.source, .googleDirectory)
        XCTAssertEqual(r?.emails.last?.state, .seen, "the directory's word, not the owner's")
        let contacts = GoogleProfile(emails: ["jo@acme.test", "jo.q@home.test"], name: "Jo Quinn", source: .contacts)
        XCTAssertEqual(DirectoryMerge.apply([contacts], to: [jo], at: t0).people[0].emails.count, 1, "only the directory gives aliases")
        let cleared = DirectoryMerge.clear([.directory], from: out, at: t0)
        XCTAssertEqual(cleared.first { $0.id.rawValue == "riley" }?.emails.map(\.address), ["riley@acme.test"], "a sign-out takes them away")
    }
}
