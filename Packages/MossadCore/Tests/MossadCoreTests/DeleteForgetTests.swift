import XCTest
@testable import MossadCore

/// The owner's decision: Delete removes everything Mossad made of a meeting, and a quit in the middle goes on.
final class DeleteForgetTests: XCTestCase {
    private let id = "20261101-100000"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteForgetTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ a: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: a.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        return l
    }

    private func pipeline(_ a: Paths, _ lib: VoiceLibrary) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: nil, notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
    }

    /// A written meeting with a voice it taught (which made "Sam Carter"), a task, a point for it alone, a series
    /// point it carried, a share link, and a chat.
    private func world() throws -> (Paths, VoiceLibrary, CallRecord, UUID, UUID) {
        let a = temp()
        let r = try writtenCall(in: a)
        let lib = library(a)
        try lib.add(r.speakerEmbeddings["them:A"]!, to: "Sam Carter",
                    source: VoiceSampleSource(callID: id, speakerKey: "them:A", recorded: r.start, seconds: 30, quality: 0.8, origin: .ownerNamed))
        var tasks = CommitmentBook()
        tasks.items = [Commitment(text: "Send the zebra budget", to: "Sam Carter", callID: id, callTitle: "Zebra budget", madeAt: t0, due: nil, created: t0)]
        try tasks.save(to: a.commitments)
        var book = NextTimeBook()
        var own = NextTimePoint(text: "Ask about the zebra", rank: 1, created: t0)
        own.meeting = NextTimeMeeting(calls: [id])
        var series = NextTimePoint(text: "The crossing", rank: 2, created: t0)
        series.seriesID = "cal:series-1"
        series.carried = [id, "20261025-100000"]
        book.points = [own, series]
        try book.save(to: a.nextTime)
        var shares = ShareBook()
        shares.links = [MeetingLink(token: "tok", callID: id, title: "Shared", options: ShareOptions(), created: t0)]
        try shares.save(to: a.shares)
        return (a, lib, r, own.id, series.id)
    }

    func testADeleteRemovesEverythingOfTheMeetingAndNoPerson() async throws {
        let (a, lib, r, own, series) = try world()
        let p = pipeline(a, lib)
        let removed = await p.deleteMeeting(callID: id)
        XCTAssertEqual(removed?.id, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path), "the folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.markdownPath!), "the note")
        XCTAssertFalse(lib.identity!.samples.samples.contains { $0.callID == id }, "no sample of the call")
        XCTAssertTrue(lib.identity!.people.people.contains { $0.isLive && $0.displayName == "Sam Carter" }, "a person the call made stays")
        XCTAssertTrue(try CommitmentBook.load(from: a.commitments).items.allSatisfy(\.deleted), "no task")
        let points = try NextTimeBook.load(from: a.nextTime).points
        let left = try XCTUnwrap(points.first { $0.id == own })
        XCTAssertTrue(left.deleted && left.text.isEmpty, "a point for that one meeting goes")
        let kept = try XCTUnwrap(points.first { $0.id == series })
        XCTAssertFalse(kept.deleted, "a series point stays")
        XCTAssertEqual(kept.carried, ["20261025-100000"], "and loses only the call")
        XCTAssertTrue(ChatStore(directory: a.chats).all().isEmpty, "no chat of the call")
        XCTAssertTrue(ShareBook.load(from: a.shares).links.allSatisfy { $0.stopping == true }, "the share links stop")
        XCTAssertNil(DeleteLedger.load(a)?.entries.first, "nothing waits")
        XCTAssertFalse(RemovedNotes.load(a).meetings.isEmpty, "its notes are never imported again")
    }

    func testADeleteThatAQuitStoppedGoesOnAtTheNextRun() async throws {
        let (a, lib, _, _, _) = try world()
        // The quit came after the first two steps.
        var deletes = DeleteLedger()
        deletes.entries = [.init(callID: id, removed: ["voices", "coach"], started: t0)]
        try deletes.save(a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        await pipeline(a, lib).runPending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        XCTAssertTrue(ChatStore(directory: a.chats).all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent(DeleteLedger.fileName).path))
    }

    func testAStepThatCannotEndWaitsAndKeepsTheMeeting() async throws {
        let (a, lib, _, _, _) = try world()
        let p = pipeline(a, lib)
        p.setForgetActions(CallForget.Actions(coach: { _ in }, stopShares: { _ in }, backup: { _ in false }, removeFolder: { _ in true }))
        let started = await p.deleteMeeting(callID: id)
        XCTAssertNotNil(started)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).path), "a link not stopped keeps the meeting")
        XCTAssertEqual(DeleteLedger.load(a)?.entries.first?.removed, ["voices", "coach", "books"])
        p.setForgetActions(nil)
        await p.finishDeletes()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
    }

    func testADeleteIsRefusedForACallThatRecordsOrMoves() async throws {
        let (a, lib, r, _, _) = try world()
        var marked = r
        marked.moveTo = "1a2b3c4d"
        try marked.save(to: a.callDirectory(id))
        let marks = await pipeline(a, lib).deleteMeeting(callID: id)
        XCTAssertNil(marks)
        var live = r
        live.status = .recording
        try live.save(to: a.callDirectory(id))
        let records = await pipeline(a, lib).deleteMeeting(callID: id)
        XCTAssertNil(records)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        XCTAssertNil(DeleteLedger.load(a)?.entries.first)
    }
}
