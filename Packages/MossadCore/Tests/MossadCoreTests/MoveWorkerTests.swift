import XCTest
@testable import MossadCore

/// A worker goes on with the moves of its own profile and takes in what another profile moved to it.
final class MoveWorkerTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let personal = "5e6f7a8b"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveWorkerTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    /// The first profile's half, as its window app runs it.
    private func source(_ a: Paths, to b: Paths) -> MoveSource {
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
        removeFolder: { id, to in await pipeline.removeMoved(callID: id, target: to) })
        let work = work
        return MoveSource(MoveSource.Setup(paths: a, profileID: personal, pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                           target: { $0 == work ? .paths(b) : .gone }, fetch: { _, _ in nil }, usage: { _ in [] },
                                           actions: actions, now: { [t0] in t0 }))
    }

    private func intake(_ b: Paths) -> MoveIntake {
        MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true })
    }

    /// A worker of a profile with fakes, as `ProfileWorkerTests` makes one.
    private func worker(_ p: Paths, me: String, target: @escaping @Sendable (String) -> MoveRules.TargetPlace, madeUp: Bool = false,
                        store: MemoryStore = MemoryStore(), calendar: CalendarSource = FakeCalendar(), archive: CloudArchive? = nil,
                        summarizer: FakeSummarizer = FakeSummarizer()) throws -> ProfileWorker {
        let made = try MadeUpSuite(self)
        made.defaults.set("Avery Webb", forKey: "ownerName")
        let settings = ServiceSettings.read(made.defaults, fullUserName: "Avery Webb")
        var setup = ProfileWorker.Setup(paths: p, settings: settings, key: { _ in "k" }, google: Keychain(service: "com.dwebber.mossad.test-none"),
                                        remember: { _, _ in }, hasICloud: false, madeUpRegistry: madeUp,
                                        macCalendarAuthorized: { false }, callRecords: { false }, now: { [t0] in t0 })
        setup.profileID = me
        setup.target = target
        let services = ProfileWorker.Services(transcriber: FakeTranscriber(), summarizer: summarizer, embeddings: ToneEmbeddingProvider(),
                                              calendar: calendar, llm: nil, main: CloudSync(paths: p, store: store), mirror: nil, archive: archive)
        return ProfileWorker(setup, services: services)
    }

    /// The meeting copied and published into `B/Incoming`, as A's window app leaves it.
    private func waiting(_ a: Paths, _ b: Paths) async throws {
        let s = source(a, to: b)
        let started = await s.start(id, to: work)
        XCTAssertEqual(started, .started)
        let waits = await s.run(id)
        XCTAssertEqual(waits, .waiting)
    }

    private func world() throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        return (a, b)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testAWorkerTakesInWhatWaitsAndFinishesIt() async throws {
        let (a, b) = try world()
        let w = try worker(b, me: work, target: { _ in .unknown })
        _ = await w.start()
        try await waiting(a, b)
        let pass = await w.pass([])
        XCTAssertTrue(pass.ran.isSuperset(of: [.takeInMoved, .queue]), "\(pass.ran)")
        let r = try CallRecord.load(from: b.callDirectory(id))
        XCTAssertEqual(r.status, .written)
        XCTAssertNil(r.moveTo)
        let notes = try FileManager.default.contentsOfDirectory(atPath: b.meetings.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(WorkerStatus.peek(root: b.root)?.inWork, 0)
    }

    func testAMeetingThatWaitsInIncomingCountsInWork() async throws {
        let (a, b) = try world()
        try await waiting(a, b)
        let status = WorkerStatus.make(records: [], incoming: MoveIntake.waitingCount(b), missing: [], backupFailed: 0, syncFailed: false, now: t0)
        XCTAssertEqual(status.inWork, 1)
        XCTAssertNil(status.failure)
        // The file keeps only its keys: a count, never an id.
        try status.save(root: b.root)
        let data = try Data(contentsOf: WorkerStatus.url(root: b.root))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertTrue(Set(keys).isSubset(of: WorkerStatus.allowedKeys), "\(keys)")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(id))
        // Once it is in `Audio`, it counts by its record and not twice.
        _ = intake(b).run()
        XCTAssertEqual(MoveIntake.waitingCount(b), 0)
    }

    func testAWorkerWithNothingWaitingStartsNoMoveDuty() async throws {
        let b = temp()
        try b.ensureDirectories()
        let w = try worker(b, me: work, target: { _ in .unknown })
        let started = await w.start()
        let pass = await w.pass([.queue, .sync])
        XCTAssertFalse(started.contains(.takeInMoved))
        XCTAssertFalse(pass.ran.contains(.takeInMoved))
        let moved = await w.moves()
        XCTAssertFalse(moved)
        XCTAssertFalse(exists(b.incoming), "no Incoming folder")
        XCTAssertFalse(exists(b.moves), "no Moves folder")
    }

    func testAWorkerFinishesTheRemovalOfItsOwnProfile() async throws {
        let (a, b) = try world()
        try await waiting(a, b)
        let w = try worker(a, me: personal, target: { [work] in $0 == work ? .paths(b) : .gone })
        let started = await w.start()
        XCTAssertFalse(started.contains(.takeInMoved), "a move that only waits is no duty that ran")
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .waiting)
        XCTAssertEqual(intake(b).run(), [id])
        let pass = await w.pass([])
        XCTAssertTrue(pass.ran.contains(.takeInMoved), "\(pass.ran)")
        XCTAssertFalse(exists(a.callDirectory(id)))
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done)
        XCTAssertFalse(exists(MoveMarker.folder(id, in: b)), "the target's Incoming is cleaned")
        XCTAssertTrue(exists(b.callDirectory(id).appendingPathComponent("recording.m4a")))
    }

    func testAWorkerRemovesBeforeItTakesIn() async throws {
        let (a, b) = try world()
        try await waiting(a, b)
        XCTAssertEqual(intake(b).run(), [id])
        // A stopped in the middle of its removal.
        var out = try XCTUnwrap(MoveOut.load(id, paths: a))
        out.state = .removing
        out.removed = ["voices", "people", "coach"]
        try out.save(a)
        // B moves the meeting back to A meanwhile: its copy waits in A's Incoming.
        let plan = try MoveCopy.plan(id, in: b, to: personal, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        _ = try MoveCopy.write(plan, from: work, token: "bacc0004", incoming: a.incoming, now: t0)
        try MoveCopy.publish(id, token: "bacc0004", incoming: a.incoming)

        let w = try worker(a, me: personal, target: { [work] in $0 == work ? .paths(b) : .gone })
        _ = await w.start()
        _ = await w.pass([])
        let audio = try FileManager.default.contentsOfDirectory(atPath: a.audio.path)
        XCTAssertEqual(audio, ["\(id)-moved"])
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done)
    }

    func testOnAMadeUpRegistryAMoveStaysInTheFolders() async throws {
        let a = temp(), b = temp()
        var r = try writtenCall(in: a)
        r.cloudKey = "recordings/\(id)/recording.m4a"
        r.cloudBackend = "server"
        r.cloudServer = "srv-1"
        r.cloudSize = 4096
        try r.save(to: a.callDirectory(id))
        try b.ensureDirectories()

        let place = FakeArchive(.server)
        let archive = CloudArchive(target: .server, places: [place], paths: a, retryPause: .zero)
        let storeA = MemoryStore(), storeB = MemoryStore()
        let calendar = ProfileWorkerTests.CountingCalendar()
        let wb = try worker(b, me: work, target: { _ in .unknown }, madeUp: true, store: storeB, calendar: calendar)
        _ = await wb.start()
        let wa = try worker(a, me: personal, target: { [work] in $0 == work ? .paths(b) : .gone }, madeUp: true, store: storeA,
                            calendar: calendar, archive: archive)
        _ = await wa.start()
        try await waiting(a, b)
        let taken = await wb.pass([.queue, .sync])
        XCTAssertTrue(taken.ran.contains(.takeInMoved))
        let removed = await wa.pass([.queue, .sync])
        XCTAssertTrue(removed.ran.contains(.takeInMoved))

        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done)
        XCTAssertTrue(exists(b.callDirectory(id)))
        let countA = await storeA.entries.count, countB = await storeB.entries.count
        XCTAssertEqual(countA, 0)
        XCTAssertEqual(countB, 0)
        XCTAssertTrue(place.removes.isEmpty, "the made-up registry reaches no backup place")
        XCTAssertEqual(CloudArchive.pendingDeletes(in: a.sync.appendingPathComponent("backup-deletes.json")).map(\.key), [r.cloudKey])
        XCTAssertEqual(calendar.count, 0)
    }

    func testTheWorkerLooksEvery15Seconds() throws {
        XCTAssertEqual(MoveRules.look, 15)
        let b = temp()
        XCTAssertFalse(MoveIntake.hasWork(b), "no folder")
        let part = b.incoming.appendingPathComponent("x.token\(MoveMarker.partSuffix)")
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        var m = MoveMarker(callID: "x", from: personal, to: work, made: t0, token: "token", files: [], ownerKeys: [])
        try m.save(in: part, claimed: false)
        XCTAssertFalse(MoveIntake.hasWork(b), "only a part")
        let x = b.incoming.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true)
        try m.save(in: x, claimed: false)
        XCTAssertTrue(MoveIntake.hasWork(b), "a marker")
        try FileManager.default.removeItem(at: x.appendingPathComponent(MoveMarker.fileName))
        m.intake = .takingIn
        try m.save(in: x, claimed: true)
        XCTAssertTrue(MoveIntake.hasWork(b), "taking in")
        m.intake = .taken
        try m.save(in: x, claimed: true)
        XCTAssertFalse(MoveIntake.hasWork(b), "taken")
    }

    func testAnInertCopyAndASecondCopyTakeNothingIn() {
        XCTAssertFalse(RunMode.inert.does(.takeInMoved))
        XCTAssertFalse(RunMode.decide(preview: false, rehearsal: false, secondCopy: true, madeUpRegistry: false).does(.takeInMoved))
        XCTAssertTrue(RunMode.worker.does(.takeInMoved))
        XCTAssertTrue(RunMode.full.does(.takeInMoved))
    }

    /// With one profile nothing changes: the window app has no look and no timer.
    func testTheWindowAppLooksOnlyWithTwoProfiles() {
        XCTAssertFalse(MoveRules.looks(mode: .full, liveProfiles: 1))
        XCTAssertFalse(MoveRules.looks(mode: .full, liveProfiles: 0))
        XCTAssertTrue(MoveRules.looks(mode: .full, liveProfiles: 2))
        XCTAssertFalse(MoveRules.looks(mode: .inert, liveProfiles: 3), "a preview, Rehearsal, a second copy, a made-up registry")
        XCTAssertFalse(MoveRules.looks(mode: .worker, liveProfiles: 2), "a worker has its own look")
    }

    /// The registry file in use, read again at each call. On a made-up registry only its own made-up folders are
    /// targets: never the first profile, which is the owner's real `~/Mossad`, and never a folder of the home's own.
    func testOnAMadeUpRegistryTheFirstProfileIsNeverATarget() throws {
        let dir = temp().root
        let b = dir.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Mossad"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("profiles.json")
        let json = """
        {"version":1,"active":"\(personal)","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},
        {"id":"\(work)","name":"Proof B","color":"green","root":"\(b.path)"},
        {"id":"\(personal)","name":"Proof H","color":"blue","root":"\(home.appendingPathComponent("Mossad").path)"}]}
        """
        try Data(json.utf8).write(to: file)
        XCTAssertEqual(MoveRules.target(work, registryFile: file, home: home, madeUpRegistry: true), .paths(Paths(root: b)))
        XCTAssertEqual(MoveRules.target("default", registryFile: file, home: home, madeUpRegistry: true), .gone)
        XCTAssertEqual(MoveRules.target(personal, registryFile: file, home: home, madeUpRegistry: true), .gone)
        XCTAssertEqual(MoveRules.target("9f9f9f9f", registryFile: file, home: home, madeUpRegistry: true), .gone)
        // The real registry: its own roots under the home, by the rule of before.
        let real = """
        {"version":1,"active":"default","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},
        {"id":"\(work)","name":"Work","color":"green","root":"~/Mossad Work"}]}
        """
        try Data(real.utf8).write(to: file)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Mossad Work"), withIntermediateDirectories: true)
        XCTAssertEqual(MoveRules.target(work, registryFile: file, home: home, madeUpRegistry: false),
                       .paths(Paths(root: home.appendingPathComponent("Mossad Work"))))
        XCTAssertEqual(MoveRules.target("default", registryFile: file, home: home, madeUpRegistry: false),
                       .paths(Paths(root: home.appendingPathComponent("Mossad"))))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(MoveRules.target(work, registryFile: file, home: home, madeUpRegistry: false), .unknown,
                       "a registry that was not read whole: the move waits and never cancels")
    }

    /// A look that finds nothing reads two folder names and writes nothing: no folder, no file.
    func testALookThatFindsNothingWritesNothing() throws {
        let p = temp()
        try p.ensureDirectories()
        let before = try FileManager.default.contentsOfDirectory(atPath: p.root.path).sorted()
        XCTAssertFalse(MoveRules.hasWork(p))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: p.root.path).sorted(), before)
        XCTAssertEqual(MoveIntake.waitingCount(p), 0)
        XCTAssertFalse(exists(p.incoming))
        XCTAssertFalse(exists(p.moves))
    }

    #if DEBUG
    /// The proof's made-up meeting, moved by the proof hook of A's worker and taken in by B's: nothing of it stays in A.
    func testTheProofMeetingMovesWholeAndLeavesNoWord() async throws {
        let a = temp(), b = temp()
        try a.ensureDirectories()
        try b.ensureDirectories()
        let audio = a.root.appendingPathComponent("call.caf")
        try writeSegments(audio, total: 30, [(0, 10, 200), (12, 25, 300)])
        let callID = try MoveProof.makeWritten(audio: audio, paths: a, ownerName: "Avery Webb", now: t0)
        try FileManager.default.removeItem(at: audio)
        var r = try CallRecord.load(from: a.callDirectory(callID))
        XCTAssertEqual(r.status, .summarized)
        XCTAssertEqual(r.speakerNames, ["me:A": "Avery Webb", "me:B": "Sam Carter"])
        XCTAssertEqual(r.speakerEmbeddings.values.map(\.count), [8, 8])
        XCTAssertEqual(r.utterances.count, 6)
        XCTAssertEqual(ChatStore(directory: a.chats).all().filter { $0.callID == callID }.count, 1)

        // The proofs run only on a made-up registry (review M16), as `WorkerEntry` starts them.
        let wa = try worker(a, me: personal, target: { [work] in $0 == work ? .paths(b) : .gone }, madeUp: true)
        let wb = try worker(b, me: work, target: { _ in .unknown }, madeUp: true)
        _ = await wa.start()
        _ = await wb.start()
        _ = await wa.pass([.queue])
        r = try CallRecord.load(from: a.callDirectory(callID))
        XCTAssertEqual(r.status, .written)
        await wa.proofMove(to: work)
        XCTAssertEqual(MoveOut.load(callID, paths: a)?.state, .waiting)
        _ = await wb.pass([])
        _ = await wa.pass([])
        XCTAssertEqual(MoveOut.load(callID, paths: a)?.state, .done)
        XCTAssertEqual(try CallRecord.load(from: b.callDirectory(callID)).status, .written)
        XCTAssertTrue(VoiceLibrary(directory: b.voices).profiles.contains { $0.name == "Sam Carter" })

        // No word of the call in A, except the ledger and the usage log, which stay by design.
        let e = FileManager.default.enumerator(at: a.root, includingPropertiesForKeys: [.isRegularFileKey])
        var hits: [String] = []
        while let url = e?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.pathExtension != "log",
                  url.deletingLastPathComponent().lastPathComponent != "Moves",
                  let text = try? String(contentsOf: url, encoding: .utf8), text.contains(MoveProof.mark) else { continue }
            hits.append(url.lastPathComponent)
        }
        XCTAssertEqual(hits, [])
    }

    func testTheProofStopsAtItsState() async throws {
        let (a, b) = try world()
        XCTAssertFalse(ProfileWorker.proofStops("copied", paths: a))
        let s = source(a, to: b)
        _ = await s.start(id, to: work)
        _ = await s.advance(id)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .copied)
        XCTAssertTrue(ProfileWorker.proofStops("copied", paths: a))
        XCTAssertFalse(ProfileWorker.proofStops("takingIn", paths: a))
        XCTAssertFalse(ProfileWorker.proofStops(nil, paths: a))
        _ = await s.run(id)
        XCTAssertFalse(ProfileWorker.proofStops("takingIn", paths: b))
        let i = intake(b)
        XCTAssertEqual(i.step(id), .claim)
        XCTAssertFalse(ProfileWorker.proofStops("takingIn", paths: b))
        _ = i.step(id)
        XCTAssertTrue(ProfileWorker.proofStops("takingIn", paths: b))
    }
    #endif
}
