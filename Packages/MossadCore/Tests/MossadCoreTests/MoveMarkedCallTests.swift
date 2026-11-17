import XCTest
@testable import MossadCore

/// While a move waits the meeting is the first profile's, and nothing changes it: no owner command, no runner, no
/// upload, and no new chat; in the target, nothing syncs a meeting before it is taken in.
final class MoveMarkedCallTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveMarkedCallTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func pipeline(_ a: Paths) -> Pipeline {
        let lib = VoiceLibrary(directory: a.voices)
        lib.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        return Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                        summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
    }

    private func marked(_ a: Paths, status: CallStatus = .written) throws -> CallRecord {
        var r = try writtenCall(in: a)
        r.moveTo = work
        r.status = status
        if status == .failed { r.failedStep = .summarized }
        r.markers = [TranscriptMarker(offset: 12, text: "★", isBookmark: true, note: "Budget")]
        try r.save(to: a.callDirectory(id))
        return r
    }

    private func bytes(_ a: Paths) throws -> Data { try Data(contentsOf: a.callDirectory(id).appendingPathComponent(CallRecord.fileName)) }

    /// I1: each owner command that changes a meeting is refused while it is marked, and changes nothing.
    func testEveryOwnerCommandIsRefusedOnAMarkedCall() async throws {
        let a = temp()
        _ = try marked(a, status: .failed)
        let p = pipeline(a)
        let before = try bytes(a)
        await p.retry(id)
        await p.setTags(callID: id, ["Other"])
        await p.setTitle(callID: id, "Another title")
        let note = await p.setBookmarkNote(callID: id, offset: 12, note: "Changed")
        let removed = await p.removeBookmark(callID: id, offset: 12)
        let added = await p.addBookmark(callID: id, offset: 20)
        let screen = await p.deleteScreen(callID: id, file: "000012000.heic")
        await p.dismissSpeakers(callID: id, keys: ["them:B"])
        await p.restoreSpeakers(callID: id, keys: ["them:B"])
        let renamed = await p.renamePerson("Sam Carter", to: "Samuel Carter")
        XCTAssertFalse(note); XCTAssertFalse(removed); XCTAssertFalse(added); XCTAssertFalse(screen)
        XCTAssertEqual(renamed, 0)
        XCTAssertEqual(try bytes(a), before, "the marked record did not change")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent("frames/000012000.heic").path))
        XCTAssertEqual(MoveWords.moving(to: "Work"), "This meeting is moving to Work. Wait, or cancel the move.")
        // The mark itself and the archive's own marks still go through.
        let unmarked = await p.setMoveTarget(callID: id, nil)
        XCTAssertTrue(unmarked)
        await p.setTitle(callID: id, "Another title")
        XCTAssertEqual(try CallRecord.load(from: a.callDirectory(id)).customTitle, "Another title")
    }

    /// I7: the runners leave a marked call alone.
    func testTheRunnersSkipAMarkedCall() throws {
        let a = temp()
        let r = try marked(a)
        XCTAssertTrue(CoachRunner.pending([r], owner: "Avery Webb", since: .distantPast, reviewed: []).isEmpty, "the coach")
        XCTAssertTrue(PersonaRunner.due([r], ledger: PersonaLedger(), since: nil, saved: CoachPeople(people: []), owner: "Avery Webb").isEmpty,
                      "the reads")
        var book = NextTimeBook()
        book.points = [NextTimePoint(text: "Hiring", personName: "Sam Carter", rank: 1, created: r.start.addingTimeInterval(-86_400))]
        XCTAssertTrue(NextTimeRules.pending([r], book: book, now: r.end.addingTimeInterval(3600)).isEmpty, "the next-time check")
        var plain = r
        plain.moveTo = nil
        XCTAssertFalse(NextTimeRules.pending([plain], book: book, now: r.end.addingTimeInterval(3600)).isEmpty)
        XCTAssertFalse(CoachRunner.pending([plain], owner: "Avery Webb", since: .distantPast, reviewed: []).isEmpty)
    }

    /// I7: the backup pass uploads no marked call.
    func testTheBackupPassSkipsAMarkedCall() async throws {
        let a = temp()
        _ = try marked(a)
        let place = FakeArchive(.server)
        let archive = CloudArchive(target: .server, places: [place], paths: a, retryPause: .zero)
        _ = await archive.sync(keepLocalDays: nil, pipeline: pipeline(a))
        XCTAssertEqual(place.puts, [])
    }

    /// I7: a new chat about a marked call is refused; a chat that is there can still be saved.
    func testANewChatOnAMarkedCallIsRefused() throws {
        let a = temp()
        _ = try marked(a)
        let store = ChatStore(directory: a.chats)
        var chat = Chat(title: "New")
        chat.callID = id
        XCTAssertThrowsError(try store.save(chat))
        var old = try XCTUnwrap(store.all().first { $0.callID == id })
        old.title = "Renamed"
        XCTAssertNoThrow(try store.save(old))
    }

    /// I2 and the sync: in the target, a meeting that is still being taken in is never pushed to its store.
    func testTheTargetSyncsNoMeetingBeforeTaken() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        _ = try MoveCopy.write(plan, from: "default", token: "aaaa0001", incoming: b.incoming, now: t0)
        try MoveCopy.publish(id, token: "aaaa0001", incoming: b.incoming)
        let lib = VoiceLibrary(directory: b.voices)
        lib.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices))
        let intake = MoveIntake(paths: b, me: work, library: lib, ownerName: { "Avery Webb" }, voiceFingerprints: { true })
        while !FileManager.default.fileExists(atPath: b.callDirectory(id).path) { _ = intake.step(id) }
        let store = MemoryStore()
        _ = try await CloudSync(paths: b, store: store).push()
        let types = await store.entries.values.map(\.record.type)
        XCTAssertFalse(types.contains("Meeting"), "\(types)")
    }
}
