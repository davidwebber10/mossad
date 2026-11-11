import XCTest
@testable import MossadCore

/// The owner's org matches by person id: a rename keeps them, and the file by name stays for older builds.
final class PeopleLocalTests: XCTestCase {
    var paths: Paths!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    private func store() throws -> (PeopleStore, PersonID, PersonID) {
        let people = PeopleStore(directory: paths.people, now: { [t0] in t0 })
        let sam = try people.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        let dana = try people.ensure(voiceName: "Dana Lee", isOwner: false, origin: .voiceNaming)
        return (people, sam, dana)
    }

    func testOldMatchesByNameGetTheirPersonAndARenameKeepsThem() throws {
        let (people, sam, dana) = try store()
        var byName = OrgMatches()
        byName.set("Sam Carter", to: "carter, sam")
        byName.setOutside("Dana Lee")
        byName.set("Nobody Saved", to: "x, y")
        // An older build wrote the file by name only.
        let encoder = JSONEncoder()
        try encoder.encode(byName).write(to: OrgMatches.url(paths))
        XCTAssertTrue(try OrgMatches.load(paths: paths).saveByPerson(paths: paths))
        XCTAssertEqual(PeopleLocal.load(paths: paths)?.org, [sam.rawValue: "carter, sam", dana.rawValue: OrgMatches.outside])
        XCTAssertFalse(try OrgMatches.load(paths: paths).saveByPerson(paths: paths), "a second run writes nothing")

        try people.rename(sam, to: "Sam Brooks")
        let after = OrgMatches.load(paths: paths)
        XCTAssertEqual(after.personID(for: "Sam Brooks"), "carter, sam", "one write to the people file, and the match stays")
        XCTAssertTrue(after.isOutside("Dana Lee"))
        XCTAssertEqual(after.personID(for: "Nobody Saved"), "x, y", "a match with no person stays by its name")
    }

    func testAClearedMatchLeavesTheFileByIdToo() throws {
        let (_, sam, _) = try store()
        var m = OrgMatches()
        m.set("Sam Carter", to: "carter, sam")
        try m.save(paths: paths)
        XCTAssertEqual(PeopleLocal.load(paths: paths)?.org[sam.rawValue], "carter, sam")
        var loaded = OrgMatches.load(paths: paths)
        loaded.clear("Sam Carter")
        try loaded.save(paths: paths)
        XCTAssertNil(PeopleLocal.load(paths: paths)?.org[sam.rawValue])
        XCTAssertNil(OrgMatches.load(paths: paths).personID(for: "Sam Carter"))
    }

    func testTwoPeopleWithOneNameGetNoMatchById() throws {
        let people = PeopleStore(directory: paths.people, now: { [t0] in t0 })
        let one = Person(displayName: "Sam Carter", origin: .owner, at: t0), two = Person(displayName: "Sam Carter", origin: .owner, at: t0)
        try people.replaceAll([one, two])
        var m = OrgMatches()
        m.set("Sam Carter", to: "carter, sam")
        try m.save(paths: paths)
        XCTAssertNil(PeopleLocal.load(paths: paths), "no file: nobody is surely that name")
        XCTAssertEqual(OrgMatches.load(paths: paths).personID(for: "Sam Carter"), "carter, sam", "the match by name stays")
    }

    func testWithNoPeopleNothingIsWrittenById() throws {
        var m = OrgMatches()
        m.set("Sam Carter", to: "carter, sam")
        try m.save(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PeopleLocal.url(paths).path))
    }

    func testAFileThisBuildCannotReadIsNotWrittenOver() throws {
        _ = try store()
        try Data("{not json".utf8).write(to: PeopleLocal.url(paths))
        var m = OrgMatches()
        m.set("Sam Carter", to: "carter, sam")
        try m.save(paths: paths)
        XCTAssertEqual(try String(contentsOf: PeopleLocal.url(paths), encoding: .utf8), "{not json")
    }
}

extension PeopleLocalTests {
    func testTwoPeopleCalledDifferentStayDifferentThroughARename() throws {
        let people = PeopleStore(directory: paths.people)
        let sam = try people.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        let other = try people.ensure(voiceName: "Sam Cartier", isOwner: false, origin: .voiceNaming)
        let pair = PeopleDuplicates.Pair(first: "Sam Carter", second: "Sam Cartier", reason: .similarName)
        XCTAssertFalse(PeopleDuplicates.isDistinct(pair, among: people.people))
        try people.setDistinct(sam, other)
        XCTAssertTrue(PeopleDuplicates.isDistinct(pair, among: people.people))
        try people.rename(other, to: "Sam Carteer")
        let renamed = PeopleDuplicates.Pair(first: "Sam Carteer", second: "Sam Carter", reason: .similarName)
        XCTAssertTrue(PeopleDuplicates.isDistinct(renamed, among: PeopleStore(directory: paths.people).people), "the pair does not come back after a rename")
    }
}
