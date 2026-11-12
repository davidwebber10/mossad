import XCTest
@testable import MossadCore

/// The review of the addresses: the company domains never make two people one, the naming flow and the edit sheet
/// keep each address with one person, and the iPhone gets what the owner allowed.
final class PersonEmailsReviewTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let domains = CompanyDomains.parse("acme.test, acmeinc.test")

    private func person(_ id: String, _ name: String, _ emails: [String]) -> Person {
        var p = Person(id: PersonID(rawValue: id), displayName: name, origin: .voiceNaming, at: t0)
        for e in emails { p.addEmail(e, state: .verified, source: .owner, at: t0) }
        return p
    }

    private func resolve(_ people: [Person], name: String? = nil, email: String, identity: SourceIdentity? = nil) -> Resolution {
        PersonResolver(people: people, domains: domains).resolve(PersonObservation(name: name, email: email, identity: identity))
    }

    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emails-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: H1: the company domains

    func testAConflictingNameOnTheInviteBlocksTheMatch() {
        let sam = person("sam", "Sam Carter", ["sam@acme.test"])
        XCTAssertNil(resolve([sam], name: "Sam Reed", email: "sam@acmeinc.test").person, "Sam Reed is another person")
        XCTAssertEqual(resolve([sam], name: "Sam Carter", email: "sam@acmeinc.test").person, PersonID(rawValue: "sam"), "the names agree")
        XCTAssertEqual(resolve([sam], name: "Carter, Sam", email: "sam@acmeinc.test").rule, .companyEmail)
    }

    func testWithNoNameOnlyALocalPartWithTheFamilyNameLinks() {
        let sam = person("sam", "Sam Carter", ["sam@acme.test", "sam.carter@acme.test", "scarter@acme.test"])
        XCTAssertEqual(resolve([sam], email: "sam.carter@acmeinc.test").person, PersonID(rawValue: "sam"))
        XCTAssertEqual(resolve([sam], email: "scarter@acmeinc.test").person, PersonID(rawValue: "sam"))
        let firstOnly = resolve([sam], email: "sam@acmeinc.test")
        XCTAssertNil(firstOnly.person, "a second Sam with no saved record can have it")
        if case .suggestion(let id, .companyEmail, _) = firstOnly { XCTAssertEqual(id.rawValue, "sam") } else { XCTFail("a suggestion at most: \(firstOnly)") }
    }

    func testARoleAddressNeverMatches() {
        let team = person("team", "Sam Carter", ["info@acme.test", "sales@acme.test", "noreply@acme.test"])
        for local in ["info", "sales", "noreply", "team", "admin", "support"] {
            XCTAssertNil(resolve([team], email: "\(local)@acmeinc.test").person, local)
            XCTAssertNotEqual(resolve([team], name: "Sam Carter", email: "\(local)@acmeinc.test").rule, .companyEmail, "the name may link; the address does not")
        }
    }

    func testAnIdOfTheSourceComesBeforeTheDomains() {
        let sam = person("sam", "Sam Carter", ["sam.carter@acme.test"])
        let identity = SourceIdentity(source: SourceKind(rawValue: "googleChat"), kind: "userID", value: "users/7", state: .verified, at: t0)
        var other = person("other", "Sam Carter", [])
        other.identities = [identity]
        XCTAssertEqual(resolve([sam, other], email: "sam.carter@acmeinc.test", identity: identity).person, PersonID(rawValue: "other"))
    }

    func testTheDirectoryReadsTheNameThatTheInviteGaveWithTheAddress() {
        let directory = PersonDirectory([.init(name: "Sam Carter", email: "sam@acme.test")], domains: domains)
        let reed = directory.with(invitees: [Invitee(name: "Sam Reed", email: "sam@acmeinc.test")])
        XCTAssertNil(reed.link(for: "sam@acmeinc.test"), "the invite says this address is Sam Reed's")
        XCTAssertNil(reed.match("sam@acmeinc.test"))
        let carter = directory.with(invitees: [Invitee(name: "Sam Carter", email: "sam@acmeinc.test")])
        XCTAssertEqual(carter.link(for: "sam@acmeinc.test"), "Sam Carter")
    }

    func testAReferenceUsesTheInvitesName() {
        let sam = person("sam", "Sam Carter", ["sam@acme.test"])
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(600), status: .written)
        r.invitees = [Invitee(name: "Sam Reed", email: "sam@acmeinc.test")]
        r.attendees = ["Sam Reed"]
        XCTAssertNil(PersonReferences(people: [sam], domains: domains).refresh(r).invitees?.first?.personID)
    }

    func testARejectedAddressIsNobodysInTheDirectory() {
        let directory = PersonDirectory([.init(name: "Sam Carter", emails: ["sam.carter@acme.test"], rejected: ["sam.carter@acmeinc.test"])], domains: domains)
        XCTAssertNil(directory.link(for: "sam.carter@acmeinc.test"))
    }

    func testTheAddressCheckRefusesTextThatIsNoAddress() {
        XCTAssertNil(CompanyDomains.split("sam carter@acme.test"))
        XCTAssertNil(CompanyDomains.split("sam@@acme.test"))
        XCTAssertNil(CompanyDomains.split("a@b@acme.test"))
        XCTAssertNotNil(CompanyDomains.split("sam.carter@acme.test"))
    }

    // MARK: M1: the domains and their suggestions

    func testAPublicMailDomainIsNeverACompanyDomain() {
        XCTAssertEqual(CompanyDomains.parse("acme.test, gmail.com, outlook.com").domains, ["acme.test"])
        XCTAssertEqual(CompanyDomains.refused(in: "acme.test, gmail.com"), ["gmail.com"])
    }

    func testSuggestionsAreTheOwnersDomainsAndThoseOfSavedPeoplesOtherAddresses() {
        let people = [["sam@acme.test", "sam@acmeinc.test"], ["jo@vendor.test"], ["riley@vendor.test"], ["kim@other.test", "kim@gmail.com"]]
        XCTAssertEqual(CompanyDomains.suggestions(ownerEmails: ["me@acme.test"], people: people), ["acme.test", "acmeinc.test"],
                       "a vendor in many invites is no suggestion; a person's second address on a public domain is none")
    }

    // MARK: H2: the naming flow and the edit sheet

    func testPickingAPersonsSecondAddressKeepsTheFirst() throws {
        let library = VoiceLibrary(directory: temp())
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        _ = try library.addEmail("sam@acmeinc.test", for: "Sam Carter")
        XCTAssertEqual(try library.setEmail("sam@acmeinc.test", for: "Sam Carter"), .alreadyTheirs)
        XCTAssertEqual(Set(library.profiles[0].emails), ["sam@acme.test", "sam@acmeinc.test"], "the picked one is first; none goes")
    }

    func testTheEditSheetNeverGivesOnePersonsAddressToAnother() throws {
        let library = VoiceLibrary(directory: temp())
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        _ = try library.addEmail("sam@acmeinc.test", for: "Sam Carter")
        try library.setEmail("riley@acme.test", for: "Riley Park")
        XCTAssertEqual(try library.setEmail("SAM@acmeinc.test", for: "Riley Park"), .belongsTo("Sam Carter"))
        XCTAssertEqual(library.profiles.first { $0.name == "Riley Park" }?.emails, ["riley@acme.test"])
        XCTAssertEqual(try library.setEmail("riley.park@acme.test", for: "Riley Park"), .added, "a new first address of their own")
        XCTAssertEqual(library.profiles.first { $0.name == "Riley Park" }?.emails, ["riley.park@acme.test"])
    }

    func testANamedVoiceWithAPersonsSecondAddressIsThatPerson() throws {
        let library = VoiceLibrary(directory: temp())
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        _ = try library.addEmail("sam@acmeinc.test", for: "Sam Carter")
        XCTAssertEqual(library.existingName(name: "Sam", email: "sam@acmeinc.test"), "Sam Carter")
    }

    func testTheDuplicateCheckComparesEachAddress() {
        let a = VoiceProfile(name: "Sam Carter", isOwner: false, embeddings: [], email: "sam@acme.test", moreEmails: ["sam@acmeinc.test"])
        let b = VoiceProfile(name: "S. C.", isOwner: false, embeddings: [], email: "sam@acmeinc.test")
        XCTAssertEqual(PeopleDuplicates.reason(a, b), .sameEmail)
    }

    // MARK: M2: "Not their address"

    func testNotTheirAddressIsSavedAsRejectedAndTheDirectoryDoesNotBringItBack() throws {
        let store = PeopleStore(directory: temp())
        let id = try store.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        try store.setEmails(["sam@acme.test"], for: id)
        try store.applyDirectory([GoogleProfile(emails: ["sam@acme.test", "sc@acmeinc.test"], name: "Sam Carter", source: .directory)])
        XCTAssertTrue(store.person(id)?.emails.contains { $0.address == "sc@acmeinc.test" && $0.state == .seen } == true)
        try store.rejectEmail("sc@acmeinc.test", for: id)
        try store.applyDirectory([GoogleProfile(emails: ["sam@acme.test", "sc@acmeinc.test"], name: "Sam Carter", source: .directory)])
        XCTAssertEqual(store.person(id)?.emails.first { $0.address == "sc@acmeinc.test" }?.state, .rejected)
        XCTAssertNil(PersonResolver(people: store.people, domains: domains).resolve(PersonObservation(name: "Sam Carter", email: "sc@acmeinc.test")).person)
    }

    // MARK: The iPhone: job, team, and domains; no photo

    func testThePhoneGetsTheJobTheTeamAndTheDomainsAndNoPhoto() throws {
        var sam = person("sam", "Sam Carter", ["sam@acme.test"])
        sam.directory = DirectoryDetails(jobTitle: "Director", department: "Operations", photoURL: URL(string: "https://example.test/p.jpg"),
                                         source: .googleDirectory, updated: t0)
        let data = SharedPayload.people([sam], domains: domains).data
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("example.test/p.jpg"), "photos stay on the Mac")
        let read = try XCTUnwrap(PeopleStore.decode(data)?.first)
        XCTAssertEqual(read.directory?.jobTitle, "Director")
        XCTAssertEqual(read.directory?.department, "Operations")
        XCTAssertNil(read.directory?.photoURL)
        XCTAssertEqual(SyncedPeople.domains(in: data), domains)
        XCTAssertEqual(SyncedPeople.domains(in: SharedPayload.people([sam], domains: .none).data), CompanyDomains.none)
    }

    // MARK: Cadence

    func testTwoMeetingsAWeekAreNotWeekly() {
        XCTAssertEqual(PersonMeetings.cadence((0..<8).map { t0.addingTimeInterval(Double($0) * 3.5 * 86_400) }, now: t0.addingTimeInterval(26 * 86_400)), .severalAWeek)
        XCTAssertEqual(PersonMeetings.cadence((0..<4).map { t0.addingTimeInterval(Double($0) * 7 * 86_400) }, now: t0.addingTimeInterval(22 * 86_400)), .weekly)
    }
}

/// The naming flow keeps each address with one person.
extension PipelineTests {
    func testNamingAVoiceAddsTheAddressAndMovesNone() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        try library.setEmail("sam@acme.test", for: "Sam Carter")
        try library.setEmail("riley@acme.test", for: "Riley Park")
        _ = try library.addEmail("sam@acmeinc.test", for: "Sam Carter")
        await p.applyNames(callID: id, names: ["them:A": "Sam Carter", "them:B": "Jo Quinn"],
                           emails: ["them:A": "sam@acmeinc.test", "them:B": "riley@acme.test"])
        XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.emails, ["sam@acme.test", "sam@acmeinc.test"], "the second address keeps the first")
        XCTAssertEqual(library.profiles.first { $0.name == "Riley Park" }?.emails, ["riley@acme.test"])
        XCTAssertFalse(library.profiles.contains { $0.name == "Jo Quinn" && $0.emails.contains("riley@acme.test") }, "never two people with one address")
    }
}
