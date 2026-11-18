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

    /// I2: a restart split the meeting into two recordings. A Delete of one keeps the owner's point for the meeting; the
    /// point only loses this call.
    func testADeleteKeepsAPointWhoseMeetingHasAnotherRecording() async throws {
        let (a, lib, r, own, _) = try world()
        var other = r
        other.id = "20261101-103500"
        other.markdownPath = nil
        try FileManager.default.createDirectory(at: a.callDirectory(other.id), withIntermediateDirectories: true)
        try other.save(to: a.callDirectory(other.id))
        _ = try NextTimeBook.change(in: a.nextTime) { book in
            book.update(own) { $0.meeting?.calls = [self.id, other.id] }
        }
        _ = await pipeline(a, lib).deleteMeeting(callID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        let point = try XCTUnwrap(try NextTimeBook.load(from: a.nextTime).points.first { $0.id == own })
        XCTAssertFalse(point.deleted, "the meeting still has a recording")
        XCTAssertEqual(point.text, "Ask about the zebra")
        XCTAssertEqual(point.meeting?.calls, [other.id], "the point only loses the deleted call")
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

/// I3: a Delete and a cut forget the call as the old Delete did; only a move drops the owner's answers.
final class DeleteCoachTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func coachRun(_ purpose: CallForget.Purpose) async throws -> CoachProfile {
        let a = Paths(root: tempDirectory())
        addTeardownBlock { try? FileManager.default.removeItem(at: a.root) }
        let r = try writtenCall(in: a)
        var p = CoachProfile()
        var q = CoachQuestion(statement: "Sam leads the budget", kind: .role, evidence: "said so", callID: r.id, at: 10, asked: t0)
        q.status = .confirmed
        p.questions.append(q)
        p.facts.append(CoachFact(kind: .role, text: "Sam leads the budget", date: t0))
        let card = CoachFinding(id: "card-\(r.id)", callID: r.id, date: t0, kind: .didWell, text: "Clear ask", skill: "asks")
        p.answers.append(FindingAnswer(card, verdict: .never, date: t0))
        p.history.append(CoachHistoryEntry(callID: r.id, title: "Zebra", date: t0, headline: "About the zebra"))
        let box = Box(p)
        let actions = CallForget.Actions(coach: { change in box.change(change) }, stopShares: { _ in }, backup: { _ in true }, removeFolder: { _ in true })
        let lib = VoiceLibrary(directory: a.voices)
        let done = try await CallForget.run(.coach, callID: r.id, purpose: purpose, paths: a, library: lib, ownerName: "Avery Webb", actions: actions, now: t0)
        XCTAssertTrue(done)
        return box.value
    }

    final class Box: @unchecked Sendable {
        var value: CoachProfile
        init(_ v: CoachProfile) { value = v }
        func change(_ c: (inout CoachProfile) -> Void) { c(&value) }
    }

    func testADeleteKeepsTheOwnersAnswersAndConfirmedFacts() async throws {
        for purpose in [CallForget.Purpose.delete, .cut([])] {
            let p = try await coachRun(purpose)
            XCTAssertEqual(p.answers.map(\.verdict), [.never], "the owner's never again stays: \(purpose)")
            XCTAssertEqual(p.facts.count, 1, "a confirmed fact stays: \(purpose)")
            XCTAssertTrue(p.history.isEmpty, "the call's review goes: \(purpose)")
            XCTAssertNil(p.movedCalls, "a deleted call is no moved call: \(purpose)")
        }
        let moved = try await coachRun(.move(gone: [], went: nil))
        XCTAssertTrue(moved.answers.isEmpty, "a move takes the answers with it, as on main")
    }
}
