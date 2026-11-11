import XCTest
@testable import MossadCore

/// Phase 2 of the move to person ids on the made-up data folder of `PeopleMigrationTests`: the dry run counts the
/// references, apply writes them with a backup and a check, a second apply writes nothing, and revert takes them
/// away again.
extension PeopleMigrationTests {
    private func command(_ mode: String, out folder: URL? = nil) -> (text: String, status: Int32) {
        PeopleMigration.command(["Mossad", "--people-migration", mode] + (folder.map { ["--out", $0.path] } ?? []), paths: paths,
                                ownerName: "Avery Webb", notDuplicates: ["Dana Lee|Sam Carter"], now: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func files() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let all = FileManager.default.enumerator(at: paths.root, includingPropertiesForKeys: [.isRegularFileKey])
        let root = paths.root.resolvingSymlinksInPath().path
        while let url = all?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true, url.lastPathComponent != ".lock" else { continue }
            out[url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "")] = try Data(contentsOf: url)
        }
        return out
    }

    func testTheDryRunCountsTheReferencesAndChangesNothing() throws {
        let before = try files()
        let result = command("dry-run", out: out)
        XCTAssertEqual(result.status, 0, result.text)
        XCTAssertTrue(result.text.contains("References: 2 of 2 meetings change"), result.text)
        XCTAssertEqual(try files(), before)
        let plan = try JSONDecoder.callRecord.decode(PeopleMigration.Plan.self, from: Data(contentsOf: out.appendingPathComponent(PeopleMigration.planName)))
        let x = try XCTUnwrap(plan.report.references)
        XCTAssertEqual(x.speakers, 5)
        XCTAssertEqual(x.speakersWithID, 4, "Pat Moreno is no saved person")
        XCTAssertEqual(x.commitments, 3)
        XCTAssertEqual(x.commitmentsWithID, 2, "\"Mike Reed\" made by hand is a nickname: no id")
        XCTAssertEqual(x.orgMatchesWithID, 1)
        XCTAssertTrue(x.refused.isEmpty)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent(PeopleMigration.reportName), encoding: .utf8).contains("## References"))
    }

    func testApplyReferencesWritesTheIdsWithABackupAndASecondRunWritesNothing() throws {
        XCTAssertEqual(command("apply").status, 0)
        let before = try files()
        let result = command("apply-references")
        XCTAssertEqual(result.status, 0, result.text)
        XCTAssertTrue(result.text.contains("References written: 2 meetings, 2 commitments, the org matches by id"), result.text)
        let people = PeopleStore(directory: paths.people)
        let sam = try XCTUnwrap(people.id(forVoiceName: "Sam Carter")).rawValue
        let a = try CallRecord.load(from: paths.callDirectory("20261105-100000"))
        XCTAssertEqual(a.speakerPeople?["them:A"], sam)
        XCTAssertEqual(a.actionItems.map(\.ownerID), [sam, sam, nil, nil])
        XCTAssertEqual(a.speakerNames, ["me:A": "Avery Webb", "them:A": "Sam Carter"], "no label changes")
        let book = try CommitmentBook.load(from: paths.commitments)
        XCTAssertEqual(book.items.map(\.toID), [sam, sam, nil])
        XCTAssertEqual(PeopleLocal.load(paths: paths)?.org[sam], "carter, sam")
        // The backup holds each changed file as it was.
        let backup = ReferenceBackup.folder(paths)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("calls/20261105-100000.json")), before["/Audio/20261105-100000/call.json"])
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(CommitmentBook.fileName)), before["/Commitments/commitments.json"])
        XCTAssertEqual(try Data(contentsOf: OrgMatches.url(paths)), before["/People/org-matches.json"], "the file by name stays for older builds")
        // Again: nothing to write.
        let once = try files()
        XCTAssertTrue(command("apply-references").text.contains("References written: 0 meetings, 0 commitments."))
        XCTAssertEqual(try files(), once)
    }

    func testApplyReferencesNeedsThePeopleFirst() throws {
        let before = try files()
        let result = command("apply-references")
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.text.contains("Run apply first"), result.text)
        XCTAssertEqual(try files(), before)
    }

    func testRevertReferencesTakesTheIdsAway() throws {
        XCTAssertEqual(command("apply").status, 0)
        let before = try files()
        XCTAssertEqual(command("apply-references").status, 0)
        let result = command("revert-references")
        XCTAssertEqual(result.status, 0, result.text)
        let after = try files()
        for (file, data) in before { XCTAssertEqual(after[file], data, file) }
        XCTAssertNil(after["/People/local.json"])
        XCTAssertEqual(command("revert-references").text, "There were no ids to remove.")
    }

    func testApplyReferencesWaitsWhileTheAppIsOpen() throws {
        XCTAssertEqual(command("apply").status, 0)
        guard case .held(let lock) = InstanceLock.acquire(root: paths.root) else { return XCTFail("no lock") }
        for mode in ["apply-references", "revert-references"] { XCTAssertTrue(command(mode).text.contains("Quit Mossad first")) }
        withExtendedLifetime(lock) {}
    }

    func testARecordThatAnOlderBuildSavedGetsItsIdsBackAtTheNextApply() throws {
        XCTAssertEqual(command("apply").status, 0)
        XCTAssertEqual(command("apply-references").status, 0)
        let dir = paths.callDirectory("20261105-100000")
        let full = try CallRecord.load(from: dir)
        try PersonReferences.withoutIDs(full).save(to: dir)
        XCTAssertTrue(command("apply-references").text.contains("References written: 1 meeting,"))
        XCTAssertEqual(try CallRecord.load(from: dir), full)
    }
}
