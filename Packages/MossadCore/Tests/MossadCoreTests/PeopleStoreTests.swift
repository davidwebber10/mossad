import XCTest
@testable import MossadCore

final class PeopleStoreTests: XCTestCase {
    var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private var file: URL { dir.appendingPathComponent(PeopleStore.fileName) }

    override func setUp() { dir = tempDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(at date: Date? = nil) -> PeopleStore {
        let date = date ?? t0
        return PeopleStore(directory: dir, now: { date })
    }

    // MARK: The file

    func testAMissingFileIsAnEmptyStoreAndNothingIsWrittenUntilAChange() {
        let s = store()
        XCTAssertTrue(s.people.isEmpty)
        XCTAssertNil(s.loadError)
        XCTAssertFalse(s.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testASavedPersonReadsBackWithEachField() throws {
        let s = store()
        let id = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        try s.setEmail("Sam.Carter@Example.com", for: id)
        let back = store()
        XCTAssertEqual(back.people, s.people)
        let p = try XCTUnwrap(back.person(id))
        XCTAssertEqual(p.displayName, "Sam Carter")
        XCTAssertEqual(p.name, NameParts(given: "sam", family: "carter"))
        XCTAssertEqual(p.forms.map(\.text), ["Sam Carter"])
        XCTAssertEqual(p.forms.first?.key, "sam carter")
        XCTAssertEqual(p.email, "sam.carter@example.com")
        XCTAssertEqual(p.id.rawValue, p.id.rawValue.lowercased())
        XCTAssertNotNil(UUID(uuidString: p.id.rawValue), "the id is a UUID")
        XCTAssertTrue(back.exists)
    }

    func testTheFileHasAVersionAndPlainTextDates() throws {
        let s = store()
        _ = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, PeopleStore.currentVersion)
        let person = try XCTUnwrap((json["people"] as? [[String: Any]])?.first)
        XCTAssertEqual(person["created"] as? String, "2026-05-28T20:26:40Z")
        XCTAssertNil(person["embeddings"], "no voice sample is in this file")
    }

    func testAPersonFromAnOlderBuildReadsWithDefaults() throws {
        try Data(#"{"people":[{"id":"abc","displayName":"Sam Carter"}]}"#.utf8).write(to: file)
        let s = store()
        XCTAssertNil(s.loadError)
        let p = try XCTUnwrap(s.people.first)
        XCTAssertEqual(p.name.family, "carter")
        XCTAssertFalse(p.isOwner)
        XCTAssertTrue(p.isLive)
        XCTAssertEqual(s.resolver.resolve(PersonObservation(name: "Carter, Sam")).person, PersonID(rawValue: "abc"), "with no forms, the display name resolves")
    }

    func testAnUnreadableFileIsSetAsideAndNotReplaced() throws {
        try Data("not json".utf8).write(to: file)
        let s = store()
        XCTAssertNotNil(s.loadError)
        XCTAssertTrue(s.people.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(kept.count, 1, "the damaged file is kept beside it")
        XCTAssertTrue(StoredFile.takeUntold(in: [dir]).isEmpty, "the owner gets no notification: the file is made again from the voice library")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8), "not json")
        // The file was moved, so a save starts clean and the old data stays on disk.
        _ = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        XCTAssertEqual(store().people.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8), "not json")
    }

    func testAFileOfANewerVersionIsReadAndNeverSaved() throws {
        let newer = #"{"version":99,"people":[{"id":"abc","displayName":"Sam Carter","newField":{"x":1},"forms":[{"text":"Sam Carter","kind":"somethingNew","source":"aNewSource"}]}],"suggestions":[]}"#
        try Data(newer.utf8).write(to: file)
        let s = store()
        XCTAssertNil(s.loadError)
        XCTAssertTrue(s.isReadOnly)
        XCTAssertEqual(s.people.map(\.displayName), ["Sam Carter"], "it reads what it knows")
        XCTAssertThrowsError(try s.ensure(voiceName: "Dana Lee", isOwner: false, origin: .voiceNaming))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), newer, "and the file is as the newer build left it")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains(".unreadable-") }, "newer is not unreadable")
    }

    func testANewerFileThatThisBuildCannotReadIsNotSetAside() throws {
        try Data(#"{"version":99,"people":"a new shape"}"#.utf8).write(to: file)
        let s = store()
        XCTAssertTrue(s.isReadOnly)
        XCTAssertNotNil(s.loadError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try s.ensure(voiceName: "Dana Lee", isOwner: false, origin: .voiceNaming))
    }

    func testASaveIsOneWholeFile() throws {
        let s = store()
        for name in ["Sam Carter", "Dana Lee", "Michael Reed"] { _ = try s.ensure(voiceName: name, isOwner: false, origin: .voiceNaming) }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, [PeopleStore.logName, PeopleStore.fileName].sorted(), "no temporary file stays")
        XCTAssertEqual(store().people.count, 3)
    }

    // MARK: Changes

    func testEnsureFindsThePersonOfAVoiceNameAndMakesOneOnlyOnce() throws {
        let s = store()
        let a = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        XCTAssertEqual(try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming), a)
        XCTAssertEqual(s.id(forVoiceName: "Sam Carter"), a)
        XCTAssertNil(s.id(forVoiceName: "sam carter"), "a profile name is exact: another case is another profile today")
        XCTAssertEqual(s.people.count, 1)
    }

    func testARenameKeepsTheOldNameAsAFormerForm() throws {
        let s = store()
        let id = try s.ensure(voiceName: "Dana Lee", isOwner: false, origin: .voiceNaming)
        try s.rename(id, to: "Dana Park")
        let p = try XCTUnwrap(s.person(id))
        XCTAssertEqual(p.displayName, "Dana Park")
        XCTAssertEqual(p.forms.map { "\($0.text):\($0.kind.rawValue)" }, ["Dana Lee:former", "Dana Park:display"])
        XCTAssertEqual(p.name.family, "park")
        XCTAssertEqual(s.resolver.resolve(PersonObservation(name: "Lee, Dana")).person, id, "the old name continues to resolve")
        XCTAssertEqual(s.id(forVoiceName: "Dana Park"), id)
        XCTAssertNil(s.id(forVoiceName: "Dana Lee"))
    }

    func testAMergeIsARedirectAndKeepsEachFormAndEmail() throws {
        let s = store()
        let a = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        let b = try s.ensure(voiceName: "Carter, Sam", isOwner: false, origin: .voiceNaming)
        try s.setEmail("sam@example.com", for: a)
        try s.setEmail("s.carter@example.org", for: b)
        try s.merge(b, into: a)
        let survivor = try XCTUnwrap(s.person(a)), absorbed = try XCTUnwrap(s.person(b))
        XCTAssertEqual(absorbed.mergedInto, a)
        XCTAssertFalse(absorbed.isLive)
        XCTAssertEqual(survivor.mergedFrom, [b])
        XCTAssertEqual(Set(survivor.forms.map(\.text)), ["Sam Carter", "Carter, Sam"])
        XCTAssertEqual(survivor.forms.first { $0.text == "Carter, Sam" }?.kind, .alias)
        XCTAssertEqual(Set(survivor.emails.map(\.address)), ["sam@example.com", "s.carter@example.org"], "the second email is not dropped")
        XCTAssertEqual(survivor.email, "sam@example.com", "the survivor's own address stays the first")
        XCTAssertEqual(s.canonical(b), a, "the old id continues to resolve")
        XCTAssertEqual(s.canonical(a), a)
        XCTAssertEqual(s.resolver.resolve(PersonObservation(email: "s.carter@example.org")).person, a)
    }

    func testCanonicalFollowsAChainAndStopsInALoop() throws {
        let s = store()
        var a = testPerson("a", "A One"), b = testPerson("b", "B Two"), c = testPerson("c", "C Three")
        a.mergedInto = b.id
        b.mergedInto = c.id
        try s.replaceAll([a, b, c])
        XCTAssertEqual(s.canonical(a.id), c.id)
        c.mergedInto = a.id
        try s.replaceAll([a, b, c])
        XCTAssertEqual(s.canonical(a.id), a.id, "a loop gives the id back and does not hang")
        XCTAssertEqual(s.canonical(PersonID(rawValue: "nobody")), PersonID(rawValue: "nobody"))
    }

    func testADeletedPersonLeavesOnlyTheIdAndTheDate() throws {
        let s = store()
        let id = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        try s.setEmail("sam@example.com", for: id)
        try s.delete(id)
        let p = try XCTUnwrap(s.person(id))
        XCTAssertEqual(p.deleted, t0)
        XCTAssertEqual(p.displayName, "")
        XCTAssertTrue(p.forms.isEmpty && p.emails.isEmpty && p.identities.isEmpty)
        XCTAssertEqual(s.resolver.resolve(PersonObservation(name: "Sam Carter")), .unknown)
        // The same name later is a new person: the id is never used again.
        let again = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        XCTAssertNotEqual(again, id)
    }

    func testANewEmailReplacesTheOldOneAsThePeoplePageDoesToday() throws {
        let s = store()
        let id = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        try s.setEmail("old@example.com", for: id)
        try s.setEmail("new@example.com", for: id)
        XCTAssertEqual(s.person(id)?.emails.map(\.address), ["new@example.com"])
        try s.setEmail("  ", for: id)
        XCTAssertEqual(s.person(id)?.emails, [])
    }

    // MARK: The owner

    func testTheOwnerIsOnePerson() throws {
        let s = store()
        let me = try s.ensure(voiceName: "Avery Webb", isOwner: true, origin: .voiceNaming)
        XCTAssertEqual(s.owner?.id, me)
        XCTAssertEqual(try s.ensure(voiceName: "Avery W", isOwner: true, origin: .voiceNaming), me, "the owner's profile is the owner, under any name")
        XCTAssertEqual(s.people.filter(\.isOwner).count, 1)
    }

    func testANewOwnerNameRenamesTheOwnerAndKeepsTheOldName() throws {
        let s = store()
        let me = try s.ensure(voiceName: "Avery Webb", isOwner: true, origin: .voiceNaming)
        try s.setOwnerName("Avery Webb-Stone")
        XCTAssertEqual(s.owner?.id, me)
        XCTAssertEqual(s.owner?.displayName, "Avery Webb-Stone")
        XCTAssertEqual(s.owner?.forms.map(\.text), ["Avery Webb", "Avery Webb-Stone"])
        XCTAssertEqual(s.ownerNames, ["Avery Webb", "Avery Webb-Stone"])
        // The same name again changes nothing and writes nothing.
        let before = try Data(contentsOf: file)
        try s.setOwnerName(" Avery Webb-Stone ")
        try s.setOwnerName("")
        XCTAssertEqual(try Data(contentsOf: file), before)
        // The owner's voice profile keeps its old name in the voice file: it is still the owner.
        XCTAssertEqual(s.id(forVoiceName: "Avery Webb", isOwner: true), me)
    }

    func testAnOwnerNameWithNoOwnerYetMakesTheOwner() throws {
        let s = store()
        try s.setOwnerName("Avery Webb")
        XCTAssertEqual(s.owner?.displayName, "Avery Webb")
        XCTAssertEqual(s.people.count, 1)
    }

    // MARK: The log

    func testEachChangeIsOneLineInTheLog() throws {
        let s = store()
        let a = try s.ensure(voiceName: "Sam Carter", isOwner: false, origin: .voiceNaming)
        try s.rename(a, to: "Sam Carter-Reed")
        let lines = try String(contentsOf: dir.appendingPathComponent(PeopleStore.logName), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let entries = try lines.map { try JSONDecoder.callRecord.decode(PeopleLogEntry.self, from: Data($0.utf8)) }
        XCTAssertEqual(entries.map(\.kind), ["create", "rename"])
        XCTAssertEqual(entries[1].subject, a.rawValue)
        XCTAssertEqual(entries[1].before, "Sam Carter")
        XCTAssertEqual(entries[1].after, "Sam Carter-Reed")
    }
}
