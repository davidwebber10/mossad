import XCTest
@testable import MossadCore

/// After phase 2 a rename is one write to the people file. "Refresh labels" brings the records and the notes in
/// step, and can run again at any time.
extension PipelineTests {
    private func identity() -> PeopleStore {
        let people = PeopleStore(directory: paths.people)
        library.identity = VoiceIdentity(people: people, samples: VoiceSampleStore(directory: paths.voices))
        return people
    }

    private func namedCall() async throws -> (Pipeline, String) {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera", "them:B": "Amy Lee"])
        return (p, id)
    }

    func testANamedCallHasTheIdsOfItsPeople() async throws {
        let people = identity()
        let (_, id) = try await namedCall()
        let r = try load(id)
        XCTAssertEqual(r.speakerPeople?["them:A"], people.id(forVoiceName: "Alex Rivera")?.rawValue)
        XCTAssertEqual(r.speakerPeople?["them:B"], people.id(forVoiceName: "Amy Lee")?.rawValue)
        XCTAssertEqual(r.speakerPeople?["me:A"], people.owner?.id.rawValue)
    }

    func testARenameReachesEachRecordAndNoteAndASecondRunWritesNothing() async throws {
        let people = identity()
        let (p, id) = try await namedCall()
        let alex = try XCTUnwrap(people.id(forVoiceName: "Alex Rivera"))
        try library.rename("Alex Rivera", to: "Alex Stone")
        XCTAssertEqual(people.person(alex)?.displayName, "Alex Stone", "the rename is in the people file")
        let changed = await p.refreshLabels()
        XCTAssertEqual(changed, 1)
        let r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Stone")
        XCTAssertEqual(r.speakerPeople?["them:A"], alex.rawValue)
        let note = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        XCTAssertTrue(note.contains("Alex Stone"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ReferenceBackup.folder(paths).appendingPathComponent("calls/\(id).json").path),
                      "the record as it was before its first change")
        let bytes = try Data(contentsOf: paths.callDirectory(id).appendingPathComponent(CallRecord.fileName))
        let again = await p.refreshLabels()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(try Data(contentsOf: paths.callDirectory(id).appendingPathComponent(CallRecord.fileName)), bytes)
    }

    func testAStopAfterTheRenameIsFinishedByTheNextStartWithOnePerson() async throws {
        let people = identity()
        let (_, id) = try await namedCall()
        // The app stopped after the rename and before any record changed.
        try library.rename("Alex Rivera", to: "Alex Stone")
        var old = try load(id)
        old.speakerNames["them:A"] = "Alex Rivera"
        try old.save(to: paths.callDirectory(id))
        let changed = await pipeline().refreshLabels()
        XCTAssertEqual(changed, 1)
        let r = try load(id)
        XCTAssertEqual(r.speakerNames["them:A"], "Alex Stone")
        XCTAssertEqual(r.speakerPeople?["them:A"], people.id(forVoiceName: "Alex Stone")?.rawValue)
        XCTAssertEqual(people.people.filter(\.isLive).filter { $0.displayName.hasPrefix("Alex") }.count, 1, "one person, not two")
    }

    func testIdsThatComeBackLeaveTheNoteAsItIs() async throws {
        _ = identity()
        let (p, id) = try await namedCall()
        let full = try load(id)
        // An older build saved the record and dropped the ids. The owner edited the note by hand.
        try PersonReferences.withoutIDs(full).save(to: paths.callDirectory(id))
        let note = try XCTUnwrap(full.markdownPath)
        try (String(contentsOfFile: note, encoding: .utf8) + "\nMy own line.\n").write(toFile: note, atomically: true, encoding: .utf8)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: note))
        let changed = await p.refreshLabels()
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try load(id).speakerPeople, full.speakerPeople)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: note)), bytes, "only ids: the note is not written")
    }

    func testANoteThatIsWrittenAgainHasACopyFirst() async throws {
        _ = identity()
        let (p, id) = try await namedCall()
        let note = try XCTUnwrap(try load(id).markdownPath)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: note))
        try library.rename("Alex Rivera", to: "Alex Stone")
        _ = await p.refreshLabels()
        let copy = ReferenceBackup.folder(paths).appendingPathComponent("notes/\(URL(fileURLWithPath: note).lastPathComponent)")
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path).contains { $0.hasSuffix(".part") })
        // A deleted meeting takes the copy of its record with it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ReferenceBackup.folder(paths).appendingPathComponent("calls/\(id).json").path))
        _ = await p.delete(callID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReferenceBackup.folder(paths).appendingPathComponent("calls/\(id).json").path))
    }

    func testWithNoPeopleStoreARenameChangesTheLabelsAsBefore() async throws {
        let id = try makeRecord()
        let p = pipeline()
        await p.process(id)
        await p.applyNames(callID: id, names: ["them:A": "Alex Rivera"])
        let changed = await p.refreshLabels(renamed: ("Alex Rivera", "Alex Stone"))
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try load(id).speakerNames["them:A"], "Alex Stone")
        XCTAssertNil(try load(id).speakerPeople)
    }
}
