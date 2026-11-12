import Foundation
import XCTest
@testable import MossadCore

/// Made-up directory entries in the shape of People API v1.
enum PeopleFixture {
    static var directory: [String: Any] { [
        "people": [
            [
                "resourceName": "people/1",
                "names": [["displayName": "Sam Carter", "metadata": ["primary": true]]],
                "emailAddresses": [["value": "Sam.Carter@example.com"]],
                "organizations": [["title": "Staff Engineer", "department": "Platform", "metadata": ["primary": true]]],
                "photos": [["url": "https://lh3.googleusercontent.com/a/made-up-1", "metadata": ["primary": true]]],
            ],
            [
                "resourceName": "people/2",
                "names": [["displayName": "Jordan Lee"]],
                "emailAddresses": [["value": "jordan.lee@example.com"]],
                "photos": [["url": "https://lh3.googleusercontent.com/a/default-user", "default": true]],
            ],
            ["resourceName": "people/3", "names": [["displayName": "No Address"]]],
        ],
        "nextPageToken": "next-1",
    ] }
}

final class GooglePeopleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheRequestsAskForTheFieldsMossadKeeps() {
        let d = URLRequest(url: GooglePeopleAPI.directoryURL(pageToken: "t"))
        XCTAssertEqual(d.url?.path, "/v1/people:listDirectoryPeople")
        XCTAssertEqual(d.query("readMask"), "names,emailAddresses,organizations,photos")
        XCTAssertEqual(d.query("sources"), "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE")
        XCTAssertEqual(d.query("pageToken"), "t")
        let c = URLRequest(url: GooglePeopleAPI.contactsURL())
        XCTAssertEqual(c.url?.path, "/v1/people/me/connections")
        XCTAssertEqual(c.query("personFields"), "names,emailAddresses,organizations,photos")
    }

    func testAPageKeepsTheNameTheJobAndARealPhoto() throws {
        let page = try GooglePeopleAPI.page(StubTransport.json(PeopleFixture.directory), source: .directory)
        XCTAssertEqual(page.nextPageToken, "next-1")
        XCTAssertEqual(page.profiles.count, 2, "an entry with no address cannot be matched")
        XCTAssertEqual(page.profiles[0], GoogleProfile(emails: ["sam.carter@example.com"], name: "Sam Carter", jobTitle: "Staff Engineer",
                                                       department: "Platform", photoURL: URL(string: "https://lh3.googleusercontent.com/a/made-up-1"),
                                                       source: .directory))
        XCTAssertNil(page.profiles[1].photoURL, "Google's default picture is no photo")
    }

    func testFetchReadsEachPartThatWasGivenAndEveryPage() async throws {
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.directory]))
        let t = StubTransport { r in
            r.query("pageToken") == nil ? (200, StubTransport.json(PeopleFixture.directory))
                : (200, StubTransport.json(["people": [["names": [["displayName": "Riley Chen"]], "emailAddresses": [["value": "riley@example.com"]]]]]))
        }
        let profiles = await GooglePeopleAPI.fetch(session: GoogleSession(secrets: secrets, transport: t))
        XCTAssertEqual(profiles[.directory]?.map(\.name), ["Sam Carter", "Jordan Lee", "Riley Chen"])
        XCTAssertNil(profiles[.contacts])
        XCTAssertFalse(t.sent.contains { $0.url?.path.contains("connections") == true }, "contacts were not given")
    }

    func testFetchWithNothingReadIsUnknown() async throws {
        let secrets = MemorySecrets()
        try secrets.setClient(testClient)
        try secrets.setTokens(GoogleTokens(accessToken: "a", refreshToken: "r", expiry: Date().addingTimeInterval(3600), scopes: [.directory]))
        let profiles = await GooglePeopleAPI.fetch(session: GoogleSession(secrets: secrets, transport: StubTransport { _ in (403, Data()) }))
        XCTAssertTrue(profiles.isEmpty, "a part that failed is not read: its old copy stays")
    }

    // MARK: The merge rule

    private func person(_ name: String, emails: [String] = [], origin: SourceKind = .voiceNaming, owner: Bool = false) -> Person {
        var p = Person(displayName: name, isOwner: owner, origin: origin, at: now.addingTimeInterval(-86_400))
        for e in emails { p.addEmail(e, state: .verified, source: .owner, at: now.addingTimeInterval(-86_400)) }
        return p
    }

    private let sam = GoogleProfile(emails: ["sam.carter@example.com"], name: "Samantha Carter", jobTitle: "Staff Engineer", department: "Platform",
                                    photoURL: URL(string: "https://lh3.googleusercontent.com/a/made-up-1"), source: .directory)

    func testATypedNameStaysAndTheJobIsFilled() {
        let typed = person("Sam Carter", emails: ["sam.carter@example.com"])
        let result = DirectoryMerge.apply([sam], to: [typed], at: now)
        let p = result.people[0]
        XCTAssertEqual(p.displayName, "Sam Carter", "never overwrite a name the owner typed")
        XCTAssertTrue(p.forms.contains { $0.text == "Samantha Carter" && $0.kind == .seen && !$0.confirmed })
        XCTAssertEqual(p.directory?.jobTitle, "Staff Engineer")
        XCTAssertEqual(p.directory?.department, "Platform")
        XCTAssertEqual(p.directory?.photoURL, sam.photoURL)
        XCTAssertEqual(p.directory?.source, .googleDirectory)
        XCTAssertEqual(result.changed, [typed.id])
        XCTAssertEqual(result.log.map(\.kind), ["directory"])
    }

    func testAPersonShownAsAnAddressGetsTheRealName() {
        let addressOnly = person("sam.carter@example.com", emails: ["sam.carter@example.com"], origin: .calendar)
        let p = DirectoryMerge.apply([sam], to: [addressOnly], at: now).people[0]
        XCTAssertEqual(p.displayName, "Samantha Carter")
        XCTAssertEqual(p.name.family, "carter")
        XCTAssertTrue(p.forms.contains { $0.text == "sam.carter@example.com" && $0.kind == .former }, "the address continues to resolve")
        XCTAssertFalse(p.forms.first { $0.kind == .display }!.confirmed, "the owner did not type it")
    }

    func testAnAddressTheOwnerTypedAsTheNameStays() {
        let typed = person("sam.carter@example.com", emails: ["sam.carter@example.com"], origin: .owner)
        XCTAssertEqual(DirectoryMerge.apply([sam], to: [typed], at: now).people[0].displayName, "sam.carter@example.com")
    }

    func testTheOwnersOwnNameNeverChanges() {
        let owner = person("alex@example.com", emails: ["sam.carter@example.com"], origin: .calendar, owner: true)
        XCTAssertEqual(DirectoryMerge.apply([sam], to: [owner], at: now).people[0].displayName, "alex@example.com")
    }

    func testTwoPeopleWithOneAddressIsNobody() {
        let a = person("Sam Carter", emails: ["sam.carter@example.com"])
        let b = person("Sam C.", emails: ["sam.carter@example.com"])
        let result = DirectoryMerge.apply([sam], to: [a, b], at: now)
        XCTAssertEqual(result.people, [a, b])
        XCTAssertTrue(result.changed.isEmpty)
    }

    func testAPersonWhoseAddressesLeadToTwoProfilesIsNobody() {
        let a = person("Sam Carter", emails: ["sam.carter@example.com", "sam@other.example.com"])
        let other = GoogleProfile(emails: ["sam@other.example.com"], name: "Sam Other", jobTitle: "Designer", source: .directory)
        XCTAssertNil(DirectoryMerge.apply([sam, other], to: [a], at: now).people[0].directory)
    }

    func testARejectedOrSharedAddressIsNoMatch() {
        var a = person("Sam Carter")
        a.addEmail("sam.carter@example.com", state: .rejected, source: .owner, at: now)
        var team = person("Team")
        team.emails = [EmailIdentity(address: "sam.carter@example.com", state: .verified, shared: true, source: .owner, at: now)]
        let result = DirectoryMerge.apply([sam], to: [a, team], at: now)
        XCTAssertTrue(result.changed.isEmpty)
    }

    func testANameOnlyPersonIsNeverMatchedByName() {
        let a = person("Samantha Carter")
        XCTAssertTrue(DirectoryMerge.apply([sam], to: [a], at: now).changed.isEmpty, "the address is the key")
    }

    func testTheDirectoryWinsOverTheContactsAndTheContactsFillGaps() {
        let contact = GoogleProfile(emails: ["sam.carter@example.com"], name: "Sammy", jobTitle: "Old title", department: "Old team",
                                    photoURL: URL(string: "https://lh3.googleusercontent.com/a/contact"), source: .contacts)
        let bare = GoogleProfile(emails: ["sam.carter@example.com"], name: "Samantha Carter", jobTitle: "Staff Engineer", source: .directory)
        let p = DirectoryMerge.apply([contact, bare], to: [person("Sam Carter", emails: ["sam.carter@example.com"])], at: now).people[0]
        XCTAssertEqual(p.directory?.jobTitle, "Staff Engineer")
        XCTAssertEqual(p.directory?.department, "Old team")
        XCTAssertEqual(p.directory?.photoURL?.absoluteString, "https://lh3.googleusercontent.com/a/contact")
        XCTAssertTrue(p.forms.contains { $0.text == "Samantha Carter" })
    }

    func testTheSameReadTwiceChangesNothing() {
        let first = DirectoryMerge.apply([sam], to: [person("Sam Carter", emails: ["sam.carter@example.com"])], at: now)
        let second = DirectoryMerge.apply([sam], to: first.people, at: now.addingTimeInterval(3600))
        XCTAssertEqual(second.people, first.people)
        XCTAssertTrue(second.changed.isEmpty)
    }

    func testTheStoreSavesTheFillAndAnOlderReaderKeepsWorking() throws {
        let dir = tempDirectory()
        let store = PeopleStore(directory: dir)
        let id = try store.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        try store.setEmail("sam.carter@example.com", for: id)
        XCTAssertEqual(try store.applyDirectory([sam]), 1)
        let again = PeopleStore(directory: dir)
        XCTAssertEqual(again.person(id)?.directory?.jobTitle, "Staff Engineer")
        XCTAssertEqual(again.person(id)?.displayName, "Sam Carter")
        // The phone gets the allowed fields only: no job, no photo.
        let synced = try JSONSerialization.jsonObject(with: try JSONEncoder.callRecord.encode(SyncedPeople.Entry(again.person(id)!))) as? [String: Any]
        XCTAssertNil(synced?["directory"])
    }

    func testAnInviteeGivenOnlyAsAnAddressGetsItsName() {
        let cache = GoogleDirectoryCache(profiles: [sam, GoogleProfile(emails: ["sam.carter@example.com"], name: "Sammy", source: .contacts)], read: now)
        XCTAssertEqual(cache.names["sam.carter@example.com"], "Samantha Carter")
        let filled = DirectoryMerge.fillNames([Invitee(name: nil, email: "sam.carter@example.com"), Invitee(name: "Jo", email: "jo@example.com")],
                                              names: cache.names)
        XCTAssertEqual(filled.map(\.name), ["Samantha Carter", "Jo"])
    }

    func testTheDirectorysTitlesFillOnlyWhatTheOrgChartDidNotGive() {
        var sam = person("Sam Carter")
        sam.directory = DirectoryDetails(jobTitle: "Staff Engineer", department: nil, photoURL: nil, source: .googleDirectory, updated: now)
        var jo = person("Jo Park")
        jo.directory = DirectoryDetails(jobTitle: "Designer", department: nil, photoURL: nil, source: .googleDirectory, updated: now)
        var twin = person("Riley Chen")
        twin.directory = DirectoryDetails(jobTitle: "Analyst", department: nil, photoURL: nil, source: .googleDirectory, updated: now)
        let lines = DirectoryMerge.contextLines(for: ["Sam Carter", "Jo Park", "Riley Chen", "Nobody"], people: [sam, jo, twin, person("Riley Chen")],
                                                except: ["Jo Park, Head of Design"])
        XCTAssertEqual(lines, ["Sam Carter, Staff Engineer"])
    }

    func testTheCacheStaysOnThisMac() throws {
        let paths = Paths(root: tempDirectory())
        try GoogleDirectoryCache(profiles: [sam], read: now).save(paths)
        XCTAssertEqual(GoogleDirectoryCache.load(paths)?.profiles, [GoogleProfile(emails: sam.emails, name: sam.name, source: .directory)],
                       "the copy keeps the addresses and the name only")
        XCTAssertEqual(GoogleDirectoryCache.url(paths).deletingLastPathComponent(), paths.people)
    }
}
