import XCTest
@testable import MossadCore

/// The owner's Cancel, a target that cannot be reached, and a call that the owner marked for another profile during
/// its recording.
final class MoveCancelTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveCancelTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    final class Place: @unchecked Sendable {
        var value: MoveRules.TargetPlace
        init(_ v: MoveRules.TargetPlace) { value = v }
    }

    /// Holds the copy at its first file until it is let go, as a long copy would.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var held = false, open = false
        var reached: Bool { lock.withLock { held } }
        func let_go() { lock.withLock { open = true } }
        func step(_ name: String) {
            guard name.hasPrefix("copy ") else { return }
            lock.withLock { held = true }
            while !lock.withLock({ open }) { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    private func source(_ a: Paths, place: Place, transcriber: FakeTranscriber = FakeTranscriber(),
                        stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> (MoveSource, Pipeline) {
        let lib = library(a)
        let pipeline = Pipeline(paths: a, transcriber: transcriber, library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            var p = try CoachProfile.load(from: a.coach)
            change(&p)
            try p.save(to: a.coach)
        }, stopShares: { callID in
            var book = ShareBook.load(from: a.shares)
            book.markStopping(callID: callID)
            try? book.save(to: a.shares)
        }, backup: { r in CloudArchive.rememberDeletes(of: r, paths: a) }, removeFolder: { await pipeline.removeMoved(callID: $0) })
        let s = MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                            target: { _ in place.value }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                            now: { [t0] in t0 }, stop: stop))
        return (s, pipeline)
    }

    private func intake(_ b: Paths) -> MoveIntake {
        MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func entries(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    /// C1: the owner's Cancel while the copy runs waits for the copy, and the meeting stays in A.
    func testACancelDuringTheCopyWins() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let place = Place(.paths(b))
        let gate = Gate()
        let (s, _) = source(a, place: place, stop: { gate.step($0) })
        let started = await s.start(id, to: work)
        XCTAssertEqual(started, .started)
        let callID = id
        let copy = Task { await s.advance(callID) }
        while !gate.reached { try await Task.sleep(for: .milliseconds(10)) }
        let cancel = Task { await s.cancelMove(callID) }
        try await Task.sleep(for: .milliseconds(200))
        gate.let_go()
        _ = await copy.value
        let answer = await cancel.value
        XCTAssertEqual(answer, .cancelled)
        _ = await s.run(id)
        XCTAssertNil(MoveOut.load(id, paths: a), "the ledger of a cancelled move is gone")
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
        XCTAssertEqual(entries(b.incoming), [], "no part and no folder in B")
        XCTAssertEqual(intake(b).run(), [])
        XCTAssertEqual(entries(b.audio), [])
        XCTAssertTrue(exists(a.callDirectory(id).appendingPathComponent("recording.m4a")))
    }

    /// A ledger that changed since the step read it is never written over: a `cancelling` stays `cancelling`.
    func testAStepNeverWritesOverANewerLedger() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let place = Place(.paths(b))
        let ledgerA = a
        let (s, _) = source(a, place: place, stop: { name in
            // Another writer (the owner's Cancel of a process that ran beside it) saves `cancelling` during the copy.
            guard name == "write the marker", var out = MoveOut.load("20261101-100000", paths: ledgerA), out.state == .copying else { return }
            out.state = .cancelling
            out.cancel = .byOwner
            try out.save(ledgerA)
        })
        _ = await s.start(id, to: work)
        _ = await s.advance(id)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .cancelling)
        let end = await s.run(id)
        XCTAssertEqual(end, .cancelled(.byOwner))
        XCTAssertEqual(entries(b.incoming), [])
    }

    /// C2: with the target out of reach, Cancel changes nothing and says so; a `cancelling` ledger waits for it.
    func testACancelWithTheTargetOutOfReachWaits() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let place = Place(.paths(b))
        let (s, _) = source(a, place: place)
        _ = await s.start(id, to: work)
        let waits = await s.run(id)
        XCTAssertEqual(waits, .waiting)
        place.value = .unknown
        let answer = await s.cancelMove(id)
        XCTAssertEqual(answer, .unreachable)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .waiting)
        XCTAssertNotNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
        XCTAssertEqual(MoveWords.unreachable, "Mossad cannot reach the other profile now. Try again when it is there.")

        // A ledger that says `cancelling` (a refusal, or a Cancel before the disk went) with the target out of reach.
        var out = try XCTUnwrap(MoveOut.load(id, paths: a))
        out.state = .cancelling
        out.cancel = .byOwner
        try out.save(a)
        for look in [MoveMarker.Look.missing, .unknown, .incoming(MoveMarker(callID: id, from: "default", to: work, made: t0, token: out.token, files: [], ownerKeys: []))] {
            XCTAssertEqual(MovePlan.source(out, marker: look, part: false, target: .unknown), .wait, "\(look)")
        }
        let still = await s.run(id)
        XCTAssertEqual(still, .waiting)
        XCTAssertNotNil(MoveOut.load(id, paths: a), "the ledger stays while its marker may be in B")
        // B is back: the Cancel ends, and B never takes the meeting in.
        place.value = .paths(b)
        let end = await s.run(id)
        XCTAssertEqual(end, .cancelled(.byOwner))
        XCTAssertEqual(intake(b).run(), [])
        XCTAssertEqual(entries(b.audio), [])
        XCTAssertNil(MoveOut.load(id, paths: a))
    }

    /// I4: a call that the owner marked for another profile during its recording keeps its mark when its move fails,
    /// and A's providers get nothing of it. The owner's own Cancel takes the mark off.
    func testAFailedMoveOfACallMarkedDuringItsRecordingKeepsTheMark() async throws {
        let a = temp(), b = temp()
        try a.ensureDirectories()
        try b.ensureDirectories()
        let dir = a.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400)])
        let start = Date(timeIntervalSince1970: 1_793_520_000)
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start + 1800, status: .recorded)
        r.moveTo = work
        try r.save(to: dir)
        // B has both names: it refuses.
        for name in [id, id + "-moved"] { try FileManager.default.createDirectory(at: b.callDirectory(name), withIntermediateDirectories: true) }
        let transcriber = FakeTranscriber()
        let place = Place(.paths(b))
        let (s, pipeline) = source(a, place: place, transcriber: transcriber)
        let started = await s.start(id, to: work, afterCall: true)
        XCTAssertEqual(started, .started)
        _ = await s.run(id)
        _ = intake(b).run()
        let end = await s.run(id)
        XCTAssertEqual(end, .cancelled(.refusedIDTaken))
        XCTAssertEqual(try CallRecord.load(from: dir).moveTo, work, "the call stays marked")
        await pipeline.runPending()
        XCTAssertTrue(transcriber.calls.isEmpty, "nothing is sent from A")
        XCTAssertEqual(try CallRecord.load(from: dir).status, .recorded)

        // The owner's own Cancel of such a move: the call is processed here.
        for name in [id, id + "-moved"] { try FileManager.default.removeItem(at: b.callDirectory(name)) }
        try? FileManager.default.removeItem(at: b.incoming)
        let again = await s.start(id, to: work, afterCall: true)
        XCTAssertEqual(again, .started)
        let answer = await s.cancelMove(id)
        XCTAssertEqual(answer, .cancelled)
        XCTAssertNil(try CallRecord.load(from: dir).moveTo)
    }

    /// A move to this profile itself is refused: its own take-in would wait for its own ledger for good.
    func testAMoveToItselfIsRefused() async throws {
        let a = temp()
        try writtenCall(in: a)
        let (s, _) = source(a, place: Place(.paths(a)))
        let started = await s.start(id, to: "default")
        XCTAssertNotEqual(started, .started)
        XCTAssertNil(MoveOut.load(id, paths: a))
    }

    /// A ledger of this id that does not read (damaged, or of a newer build) is never replaced by a new move.
    func testAnUnreadableLedgerIsNeverReplaced() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        try FileManager.default.createDirectory(at: a.moves, withIntermediateDirectories: true)
        try Data("{\"version\":9}".utf8).write(to: MoveOut.url(id, paths: a))
        let (s, _) = source(a, place: Place(.paths(b)))
        let started = await s.start(id, to: work)
        XCTAssertEqual(started, .refused(MoveWords.inWork))
        XCTAssertEqual(try Data(contentsOf: MoveOut.url(id, paths: a)), Data("{\"version\":9}".utf8))
    }
}
