import XCTest
@testable import MossadCore

final class MoveEndToEndTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveEndToEndTests-\(UUID().uuidString)")
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

    private func source(_ a: Paths, place: Place, stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveSource {
        let lib = library(a)
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            var p = (try? CoachProfile.load(from: a.coach)) ?? CoachProfile()
            change(&p)
            try p.save(to: a.coach)
        }, stopShares: { callID in
            var book = ShareBook.load(from: a.shares)
            book.markStopping(callID: callID)
            try? book.save(to: a.shares)
        }, backup: { r in CloudArchive.rememberDeletes(of: r, paths: a); return true },
        removeFolder: { id, to in await pipeline.removeMoved(callID: id, target: to, stop: stop) })
        return MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                           target: { _ in place.value }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                           now: { [t0] in t0 }, stop: stop))
    }

    private func intake(_ b: Paths, stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveIntake {
        MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true }, stop: stop)
    }

    private func world() throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        return (a, b)
    }

    /// The two rules on the real folders.
    private func check(_ a: Paths, _ b: Paths, _ at: String, line: UInt = #line) {
        let inA = FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent(CallRecord.fileName).path)
        let marker: MoveMarker? = if case .claimed(let m) = MoveMarker.look(MoveMarker.folder(id, in: b)) { m } else { nil }
        let held = marker.map { m in m.heldWhole && FileManager.default.fileExists(atPath: b.callDirectory(m.finalID ?? "").appendingPathComponent(CallRecord.fileName).path) } ?? false
        let inB = FileManager.default.fileExists(atPath: b.callDirectory(id).appendingPathComponent(CallRecord.fileName).path)
        XCTAssertTrue(inA || inB, "\(at): in neither profile", line: line)
        if let out = MoveOut.load(id, paths: a), !out.removed.isEmpty || out.state == .done {
            if let marker {
                XCTAssertTrue(held && marker.token == out.token, "\(at): A removes what B does not hold by A's token", line: line)
            } else {
                // The clean-up removed the marker after the removal: the meeting is whole in B's Audio.
                let dir = b.callDirectory(id)
                XCTAssertTrue(["call.json", "me.caf", "them.caf", "recording.m4a"].allSatisfy {
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
                }, "\(at): A removed it and B does not hold it whole", line: line)
            }
        }
    }

    /// Both halves to the end, as the next launches would run them.
    private func finish(_ a: Paths, _ b: Paths, place: Place) async {
        for _ in 0..<6 {
            _ = await source(a, place: place).run(id)
            _ = intake(b).run()
        }
        _ = await source(a, place: place).run(id)
    }

    func testAMoveEndToEnd() async throws {
        let (a, b) = try world()
        let place = Place(.paths(b))
        let started = await source(a, place: place).start(id, to: work)
        XCTAssertEqual(started, .started)
        await finish(a, b, place: place)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.callDirectory(id).appendingPathComponent("recording.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MoveMarker.folder(id, in: b).path), "Incoming is cleaned")
    }

    /// One count of sub-steps across both processes: at each, the process that runs ends; the rules hold; then both
    /// halves run to the end from the ledger and the marker.
    func testTheMeetingIsNeverInNeitherProfileAtAnyStop() async throws {
        let counter = StopAt()
        do {
            let (a, b) = try world()
            let place = Place(.paths(b))
            _ = await source(a, place: place, stop: counter.step).start(id, to: work)
            for _ in 0..<6 {
                _ = await source(a, place: place, stop: counter.step).run(id)
                _ = intake(b, stop: counter.step).run()
            }
            _ = await source(a, place: place, stop: counter.step).run(id)
        }
        let total = counter.seen.count
        XCTAssertGreaterThan(total, 40, "\(counter.seen.count)")
        for n in 0..<total {
            let (a, b) = try world()
            let place = Place(.paths(b))
            let stop = StopAt(n)
            _ = await source(a, place: place, stop: stop.step).start(id, to: work)
            if MoveOut.load(id, paths: a) == nil {
                // A stop before the start saved its ledger: no move began, and the owner starts it again.
                check(a, b, "stop \(n) (\(stop.seen.last ?? "")) before the ledger")
                _ = await source(a, place: place).start(id, to: work)
            }
            var stopped = false
            for _ in 0..<6 where !stopped {
                _ = await source(a, place: place, stop: stop.step).run(id)
                stopped = stop.seen.count > n
                if stopped { break }
                _ = intake(b, stop: stop.step).run()
                stopped = stop.seen.count > n
            }
            if !stopped { _ = await source(a, place: place, stop: stop.step).run(id) }
            check(a, b, "stop \(n) (\(stop.seen.last ?? ""))")
            await finish(a, b, place: place)
            check(a, b, "after stop \(n)")
            XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done, "stop \(n) (\(stop.seen.last ?? ""))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path), "stop \(n)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.audio.path), [id], "stop \(n)")
        }
    }

    func testATargetThatGoesWhileTheMoveWaitsCancelsItAndAKeepsTheMeeting() async throws {
        let (a, b) = try world()
        let place = Place(.paths(b))
        _ = await source(a, place: place).start(id, to: work)
        let waits = await source(a, place: place).run(id)
        XCTAssertEqual(waits, .waiting)
        place.value = .gone
        let cancelled = await source(a, place: place).run(id)
        XCTAssertEqual(cancelled, .cancelled(.targetGone))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent(CallRecord.fileName).path))
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
        XCTAssertNil(MoveOut.load(id, paths: a))
        // An unknown registry waits and cancels nothing.
        _ = await source(a, place: Place(.paths(b))).start(id, to: work)
        let unknown = await source(a, place: Place(.unknown)).run(id)
        XCTAssertEqual(unknown, .waiting)
        XCTAssertNotNil(MoveOut.load(id, paths: a))
    }

    func testTheOwnersCancelAndOneThatComesTooLate() async throws {
        let (a, b) = try world()
        let place = Place(.paths(b))
        _ = await source(a, place: place).start(id, to: work)
        _ = await source(a, place: place).run(id)
        let cancel = await source(a, place: place).cancel(id)
        XCTAssertTrue(cancel)
        XCTAssertNil(MoveOut.load(id, paths: a))
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
        XCTAssertEqual(intake(b).run(), [], "a taken-back marker is never taken in")

        let (a2, b2) = try world()
        let place2 = Place(.paths(b2))
        _ = await source(a2, place: place2).start(id, to: work)
        _ = await source(a2, place: place2).run(id)
        XCTAssertTrue(MoveMarker.claim(MoveMarker.folder(id, in: b2)))
        let late = await source(a2, place: place2).cancel(id)
        XCTAssertFalse(late, "the target has the meeting already")
        XCTAssertNotNil(MoveOut.load(id, paths: a2))
    }

    func testAStartIsRefusedWithAWordAndChangesNothing() async throws {
        let (a, _) = try world()
        let gone = await source(a, place: Place(.gone)).start(id, to: work)
        XCTAssertEqual(gone, .refused(MoveWords.refusal(.targetGone, target: work) ?? ""))
        XCTAssertNil(MoveOut.load(id, paths: a))
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
    }
}
