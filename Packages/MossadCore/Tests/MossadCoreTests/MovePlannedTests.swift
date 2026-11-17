import XCTest
@testable import MossadCore

/// The tests that the plan lists for Tasks 8 and 9 and that were not written, on real folders.
final class MovePlannedTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let third = "5e6f7a8b"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MovePlannedTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    private func pipeline(_ p: Paths, summarizer: FakeSummarizer = FakeSummarizer()) -> Pipeline {
        Pipeline(paths: p, transcriber: FakeTranscriber(), library: library(p), embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: summarizer, notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
    }

    final class Flag: @unchecked Sendable {
        var fail = 0
    }

    private func actions(_ p: Paths, _ pipe: Pipeline, coachFails: Flag = Flag(),
                         stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveRemoval.Actions {
        MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            if coachFails.fail > 0 { coachFails.fail -= 1; throw CocoaError(.fileWriteUnknown) }
            var c = try CoachProfile.load(from: p.coach)
            change(&c)
            try c.save(to: p.coach)
        }, stopShares: { callID in
            var book = ShareBook.load(from: p.shares)
            book.markStopping(callID: callID)
            try? book.save(to: p.shares)
        }, backup: { r in CloudArchive.rememberDeletes(of: r, paths: p); return true },
        removeFolder: { id, to in await pipe.removeMoved(callID: id, target: to, stop: stop) })
    }

    private func source(_ a: Paths, me: String = "default", targets: [String: Paths], coachFails: Flag = Flag(),
                        stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveSource {
        let pipe = pipeline(a)
        return MoveSource(MoveSource.Setup(paths: a, profileID: me, pipeline: pipe, library: library(a), ownerName: { "Avery Webb" },
                                           target: { targets[$0].map { .paths($0) } ?? .gone }, fetch: { _, _ in nil }, usage: { _ in [] },
                                           actions: actions(a, pipe, coachFails: coachFails, stop: stop), now: { [t0] in t0 }, stop: stop))
    }

    private func intake(_ b: Paths, me: String) -> MoveIntake {
        MoveIntake(paths: b, me: me, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func entries(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    private func world() throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        return (a, b)
    }

    /// Both halves to the end.
    private func move(_ s: MoveSource, _ i: MoveIntake, _ callID: String) async -> MoveSource.Event {
        var last = MoveSource.Event.nothing
        for _ in 0..<6 {
            let e = await s.run(callID)
            if e != .nothing { last = e }
            _ = i.run()
        }
        return last
    }

    // MARK: Task 8

    func testTheOrderOfTheRemoval() {
        XCTAssertEqual(MoveOut.Step.allCases, [.voices, .people, .coach, .books, .shares, .backup, .notes, .folder])
    }

    func testEveryVoiceSampleOfTheCallIsForgotten() async throws {
        let a = temp()
        var r = try writtenCall(in: a)
        r.moveTo = work
        try r.save(to: a.callDirectory(id))
        let lib = library(a)
        let other: [Float] = [0.2, 0.1, 0.9, 0.1, 0.1, 0.3, 0.1, 0.1]
        try lib.add(r.speakerEmbeddings["them:A"]!, to: "Sam Carter",
                    source: VoiceSampleSource(callID: id, speakerKey: "them:A", recorded: r.start, seconds: 30, quality: 0.8, origin: .ownerNamed))
        try lib.add(other, to: "Sam Carter",
                    source: VoiceSampleSource(callID: "20261020-100000", speakerKey: "them:A", recorded: r.start, seconds: 30, quality: 0.8, origin: .ownerNamed))
        var out = MoveOut(callID: id, to: work, started: t0)
        let ok = try await MoveRemoval.run(.voices, out: out, paths: a, library: lib, ownerName: "Avery Webb", actions: actions(a, pipeline(a)), now: t0)
        XCTAssertTrue(ok)
        let after = library(a)
        XCTAssertEqual(after.profiles.first { $0.name == "Sam Carter" }?.embeddings, [other])
        XCTAssertFalse(after.identity?.samples.samples.contains { $0.callID == id } ?? true)
        out.removed = []
        let again = try await MoveRemoval.run(.voices, out: out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, pipeline(a)), now: t0)
        XCTAssertTrue(again)
        XCTAssertEqual(library(a).profiles.first { $0.name == "Sam Carter" }?.embeddings, [other])
    }

    func testARecordedMeetingIsRemovedToo() async throws {
        let a = temp()
        var r = try writtenCall(in: a)
        r.status = .recorded
        r.moveTo = work
        try r.save(to: a.callDirectory(id))
        let removed = await pipeline(a).removeMoved(callID: id, target: work)
        XCTAssertTrue(removed)
        XCTAssertFalse(exists(a.callDirectory(id)))
        var plain = try writtenCall(in: a, id: "20261103-100000")
        plain.status = .recorded
        try plain.save(to: a.callDirectory(plain.id))
        let refused = await pipeline(a).removeMoved(callID: plain.id, target: work)
        XCTAssertFalse(refused, "a record with no mark stays")
        XCTAssertTrue(exists(a.callDirectory(plain.id)))
    }

    func testTheUsageLogKeepsTheCallsRowsAndTheGeminiNotesAreNotImportedAgain() async throws {
        let a = try world().a
        var r = try CallRecord.load(from: a.callDirectory(id))
        r.moveTo = work
        r.gemini = GeminiNotesRef(docID: "d1", title: "Notes", url: nil, eventID: "e1", imported: t0, notes: nil)
        try r.save(to: a.callDirectory(id))
        let usage = UsageLog(directory: a.usage)
        usage.record(UsageEvent(date: t0, callID: id, service: .assemblyai, purpose: .transcription, model: nil, audioSeconds: 1800))
        usage.record(UsageEvent(date: t0, callID: id, service: .claude, purpose: .summary, model: "m", inputTokens: 10, outputTokens: 5))
        let before = usage.events(forCall: id).events
        var out = MoveOut(callID: id, to: work, started: t0)
        out.state = .removing
        try out.save(a)
        let pipe = pipeline(a)
        try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, pipe), now: t0)
        XCTAssertNil(out.nextStep)
        XCTAssertEqual(UsageLog(directory: a.usage).events(forCall: id).events, before)
        XCTAssertTrue(RemovedNotes.load(a).ids.isSuperset(of: ["d1", "e1"]))
    }

    func testAStepOfAFolderThatIsGoneIsDone() async throws {
        let a = temp()
        try a.ensureDirectories()
        let before = entries(a.root)
        let pipe = pipeline(a)
        var out = MoveOut(callID: id, to: work, started: t0)
        out.people = []
        for step in MoveOut.Step.allCases {
            let ok = try await MoveRemoval.run(step, out: out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, pipe), now: t0)
            XCTAssertTrue(ok, "\(step)")
        }
        XCTAssertEqual(entries(a.root), before)
    }

    // MARK: Task 9

    func testTheTargetRefuses() async throws {
        let (a, b) = try world()
        for name in [id, id + "-moved"] { try writtenCall(in: b, id: name) }
        let others = entries(b.audio)
        let s = source(a, targets: [work: b])
        _ = await s.start(id, to: work)
        let end = await move(s, intake(b, me: work), id)
        XCTAssertEqual(end, .cancelled(.refusedIDTaken))
        XCTAssertTrue(exists(a.callDirectory(id).appendingPathComponent("recording.m4a")))
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
        XCTAssertEqual(entries(b.incoming), [])
        XCTAssertEqual(entries(b.audio), others)
    }

    func testTheSameMeetingCannotMoveTwice() async throws {
        let (a, b) = try world()
        let c = temp()
        try c.ensureDirectories()
        let s = source(a, targets: [work: b, third: c])
        let first = await s.start(id, to: work)
        XCTAssertEqual(first, .started)
        let second = await s.start(id, to: third)
        XCTAssertEqual(second, .refused(MoveWords.inWork))
        XCTAssertFalse(exists(c.incoming))
        let cancelled = await s.cancelMove(id)
        XCTAssertEqual(cancelled, .cancelled)
        let again = await s.start(id, to: third)
        XCTAssertEqual(again, .started)
    }

    /// A to B, B's pipeline writes it there, then back to A: it arrives as `<id>-moved`, whole, and B keeps nothing.
    func testAMoveBackAndBsPipelineAfterTheMove() async throws {
        let (a, b) = try world()
        let firstHashes = try ["me.caf", "them.caf", "recording.m4a"].map { try FileHash.sha256(of: a.callDirectory(id).appendingPathComponent($0)) }
        let out = source(a, targets: [work: b])
        let started0 = await out.start(id, to: work)
        XCTAssertEqual(started0, .started)
        let there = await move(out, intake(b, me: work), id)
        XCTAssertEqual(there, .moved(to: work))
        let summarizer = FakeSummarizer()
        await pipeline(b, summarizer: summarizer).runPending()
        XCTAssertEqual(try CallRecord.load(from: b.callDirectory(id)).status, .written)
        XCTAssertEqual(entries(b.meetings).count, 1)
        let back = source(b, me: work, targets: ["default": a])
        let started = await back.start(id, to: "default")
        XCTAssertEqual(started, .started)
        let end = await move(back, intake(a, me: "default"), id)
        XCTAssertEqual(end, .moved(to: "default"))
        let moved = a.callDirectory(id + "-moved")
        XCTAssertEqual(try ["me.caf", "them.caf", "recording.m4a"].map { try FileHash.sha256(of: moved.appendingPathComponent($0)) }, firstHashes)
        XCTAssertFalse(exists(b.callDirectory(id)))
        XCTAssertTrue(library(a).profiles.contains { $0.name == "Sam Carter" })
    }

    func testAFailedRemovalStepStopsAndGoesOn() async throws {
        let (a, b) = try world()
        let fails = Flag()
        let s = source(a, targets: [work: b], coachFails: fails)
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        _ = intake(b, me: work).run()
        fails.fail = 1
        let stopped = await s.run(id)
        XCTAssertEqual(stopped, .waiting)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.removed, ["voices", "people"])
        XCTAssertTrue(exists(a.callDirectory(id)))
        XCTAssertTrue(exists(b.callDirectory(id).appendingPathComponent("recording.m4a")))
        let end = await s.run(id)
        XCTAssertEqual(end, .moved(to: work))
    }

    /// A stop at each point of a cancel (before and after the marker was taken back): the next run ends it, A keeps
    /// the meeting whole and unmarked, and B never takes it in.
    func testACancelNeverLeavesTheMeetingInBoth() async throws {
        let counter = StopAt()
        var begin = 0
        do {
            let (a, b) = try world()
            let s = source(a, targets: [work: b], stop: counter.step)
            _ = await s.start(id, to: work)
            _ = await s.run(id)
            begin = counter.seen.count
            _ = await s.cancelMove(id)
        }
        XCTAssertGreaterThan(counter.seen.count - begin, 4, "\(counter.seen.suffix(8))")
        for n in begin..<counter.seen.count {
            let (a, b) = try world()
            let stop = StopAt(n)
            let s = source(a, targets: [work: b], stop: stop.step)
            _ = await s.start(id, to: work)
            _ = await s.run(id)
            _ = await s.cancelMove(id)
            // The next launch: a new source without stops, and B's intake.
            let next = source(a, targets: [work: b])
            _ = await next.run(id)
            _ = intake(b, me: work).run()
            _ = await next.run(id)
            let at = stop.seen.last ?? ""
            _ = await next.run(id)
            let inA = exists(a.callDirectory(id).appendingPathComponent("recording.m4a"))
            let inB = exists(b.callDirectory(id).appendingPathComponent("recording.m4a"))
            XCTAssertTrue(inA != inB, "stop \(n) (\(at)): in A \(inA), in B \(inB)")
            if inA {
                // The cancel was saved before the stop: it ends, and B never takes the meeting in.
                XCTAssertNil(MoveOut.load(id, paths: a), "stop \(n) (\(at))")
                XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo, "stop \(n) (\(at))")
                XCTAssertEqual(entries(b.incoming), [], "stop \(n) (\(at))")
            } else {
                // The process ended before the cancel was saved: the owner was never told "cancelled", the move went on.
                XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done, "stop \(n) (\(at))")
                XCTAssertTrue(["cancel: take back", "cancel: save cancelling"].contains(at), "stop \(n) (\(at)): a saved cancel was lost")
            }
        }
    }

    /// A symbolic link under a name that goes as it is refuses the move: its file would be left out with no word.
    func testALinkUnderAKnownNameRefusesTheMove() throws {
        let a = temp()
        try writtenCall(in: a)
        let dir = a.callDirectory(id)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("them.caf"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("them.caf"), withDestinationURL: dir.appendingPathComponent("me.caf"))
        XCTAssertThrowsError(try MovedFiles.list(in: dir))
        XCTAssertThrowsError(try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil))
    }

    /// The plan of a copy is of the asked id only.
    func testThePlanIsOfTheAskedID() throws {
        let a = temp()
        var r = try writtenCall(in: a)
        r.id = "20261101-100001"
        try r.save(to: a.callDirectory(id))
        XCTAssertThrowsError(try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil))
    }
}
