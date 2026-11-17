import XCTest
@testable import MossadCore

/// The copy, its hashes, and the take-in wait while a call records; a copy that runs finishes its file and waits at
/// the next one, and goes on from its part after the call.
final class MoveCallHoldTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let token = "aaaa0001"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveCallHoldTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool?
        init(_ v: Bool?) { on = v }
        var value: Bool? { lock.withLock { on } }
        func set(_ v: Bool?) { lock.withLock { on = v } }
    }

    private func source(_ a: Paths, _ b: Paths, calling: Flag) -> MoveSource {
        let lib = library(a)
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in },
                                          backup: { _ in true }, removeFolder: { id, to in await pipeline.removeMoved(callID: id, target: to) })
        var setup = MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                     target: { _ in .paths(b) }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                     now: { [t0] in t0 })
        setup.calling = { calling.value }
        return MoveSource(setup)
    }

    private func world() throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        return (a, b)
    }

    func testTheTableOfWhenAPartOfAMoveRuns() {
        // (work, call records, worker) -> plan. A call that cannot be told is a call.
        let table: [(MoveWork, Bool?, Bool, MoveWorkPlan)] = [
            (.startCopy, false, false, .run), (.startCopy, false, true, .behind), (.startCopy, true, false, .hold), (.startCopy, true, true, .hold), (.startCopy, nil, true, .hold),
            (.nextFile, false, false, .run), (.nextFile, false, true, .behind), (.nextFile, true, false, .hold), (.nextFile, true, true, .hold), (.nextFile, nil, true, .hold),
            (.takeIn, false, false, .run), (.takeIn, false, true, .behind), (.takeIn, true, false, .hold), (.takeIn, true, true, .hold), (.takeIn, nil, true, .hold),
            (.smallStep, false, false, .run), (.smallStep, false, true, .behind), (.smallStep, true, false, .behind), (.smallStep, true, true, .behind), (.smallStep, nil, true, .behind),
        ]
        XCTAssertEqual(Set(table.map(\.0)), Set(MoveWork.allCases))
        for (work, call, worker, plan) in table {
            XCTAssertEqual(MoveWorkPlan.plan(work, callRecording: call, worker: worker), plan, "\(work) \(String(describing: call)) \(worker)")
        }
        XCTAssertEqual(MoveWorkPlan.run.priority, .utility)
        XCTAssertEqual(MoveWorkPlan.behind.priority, .background)
    }

    func testACopyDoesNotStartWhileACallRecords() async throws {
        let (a, b) = try world()
        let calling = Flag(true)
        let s = source(a, b, calling: calling)
        let started = await s.start(id, to: work)
        XCTAssertEqual(started, .started)
        let held = await s.run(id)
        XCTAssertEqual(held, .waiting)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .copying)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: b.incoming.path)) ?? [], [], "nothing is written in B during the call")
        calling.set(nil)
        let unknown = await s.run(id)
        XCTAssertEqual(unknown, .waiting)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .copying, "a call that cannot be told holds it too")
        calling.set(false)
        let after = await s.run(id)
        XCTAssertEqual(after, .waiting)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .waiting, "after the call the copy runs and is published")
    }

    func testACopyThatRunsWaitsAtTheNextFileAndGoesOnFromItsPart() throws {
        let (a, b) = try world()
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        XCTAssertGreaterThan(plan.files.count, 1)
        var copied: [String] = []
        let counting: MoveCopy.FileCopy = { from, to, progress in
            copied.append(from.lastPathComponent)
            return try MoveCopy.file(from, to, progress)
        }
        // The call starts during the first file: that file finishes, and the copy waits at the next.
        XCTAssertThrowsError(try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0, copy: counting,
                                                held: { !copied.isEmpty })) { XCTAssertTrue($0 is MoveCopy.Held) }
        XCTAssertEqual(copied.count, 1)
        let part = MoveCopy.part(id, token: token, incoming: b.incoming)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.appendingPathComponent(plan.files[0].path).path), "the part is kept")
        XCTAssertFalse(MoveCopy.hasPart(id, token: token, incoming: b.incoming), "a held part is never whole")
        // After the call: the file that is whole in the part is not copied again.
        copied = []
        let marker = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0, copy: counting, held: { false })
        XCTAssertEqual(copied.count, plan.files.count - 1)
        try MoveCopy.publish(id, token: token, incoming: b.incoming)
        let folder = MoveMarker.folder(id, in: b)
        for f in marker.files { XCTAssertEqual(try FileHash.sha256(of: folder.appendingPathComponent(f.path)), f.sha256, f.path) }
    }

    func testAPartWithAFileThatChangedIsCopiedAgain() throws {
        let (a, b) = try world()
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        var n = 0
        XCTAssertThrowsError(try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0,
                                                held: { n += 1; return n > 1 }))
        let part = MoveCopy.part(id, token: token, incoming: b.incoming)
        let first = part.appendingPathComponent(plan.files[0].path)
        // A file cut short by the end of the process, and a stray file that is not in the plan.
        let h = try FileHandle(forWritingTo: first)
        try h.truncate(atOffset: 3)
        try h.close()
        try Data("stray".utf8).write(to: part.appendingPathComponent("\(MoveMarker.callFolder)/stray.bin"))
        let marker = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.appendingPathComponent("\(MoveMarker.callFolder)/stray.bin").path))
        for f in marker.files { XCTAssertEqual(try FileHash.sha256(of: part.appendingPathComponent(f.path)), f.sha256, f.path) }
    }

    func testATakeInDoesNotStartWhileACallRecords() async throws {
        let (a, b) = try world()
        let s = source(a, b, calling: Flag(false))
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        let intake = MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true })
        XCTAssertEqual(intake.run(held: { true }), [])
        guard case .incoming = MoveMarker.look(MoveMarker.folder(id, in: b)) else { return XCTFail("the marker is not claimed during the call") }
        XCTAssertEqual(intake.run(held: { false }), [id])
    }

    func testAWorkerTakesNothingInWhileACallRecords() async throws {
        let (a, b) = try world()
        let calling = Flag(true)
        let made = try MadeUpSuite(self)
        made.defaults.set("Avery Webb", forKey: "ownerName")
        let settings = ServiceSettings.read(made.defaults, fullUserName: "Avery Webb")
        var setup = ProfileWorker.Setup(paths: b, settings: settings, key: { _ in "k" }, google: Keychain(service: "com.dwebber.mossad.test-none"),
                                        remember: { _, _ in }, hasICloud: false, madeUpRegistry: false,
                                        macCalendarAuthorized: { false }, callRecords: { calling.value ?? true }, now: { [t0] in t0 })
        setup.profileID = work
        let services = ProfileWorker.Services(transcriber: FakeTranscriber(), summarizer: FakeSummarizer(), embeddings: ToneEmbeddingProvider(),
                                              calendar: FakeCalendar(), llm: nil, main: nil, mirror: nil, archive: nil)
        let w = ProfileWorker(setup, services: services)
        _ = await w.start()
        let s = source(a, b, calling: Flag(false))
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        let during = await w.moves()
        XCTAssertFalse(during)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.callDirectory(id).path))
        calling.set(false)
        let after = await w.moves()
        XCTAssertTrue(after)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.callDirectory(id).path))
    }
}
