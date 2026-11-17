import XCTest
@testable import MossadCore

/// The tests the last review found missing (Y9), and its Minor findings that this branch fixes.
final class MoveReviewFourTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveReviewFourTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    private func pipeline(_ a: Paths, _ lib: VoiceLibrary) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
    }

    @discardableResult
    private func marked(_ a: Paths, status: CallStatus = .written) throws -> CallRecord {
        var r = try writtenCall(in: a)
        r.status = status
        r.moveTo = work
        try r.save(to: a.callDirectory(id))
        return r
    }

    private func source(_ a: Paths, _ b: Paths) -> MoveSource {
        let lib = library(a)
        let p = pipeline(a, lib)
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in }, backup: { _ in true },
                                          removeFolder: { id, to in await p.removeMoved(callID: id, target: to) })
        return MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: p, library: lib, ownerName: { "Avery Webb" },
                                           target: { _ in .paths(b) }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                           now: { [t0] in t0 }))
    }

    private func listing(_ dir: URL) -> [String: Int64] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: Int64] = [:]
        for case let url as URL in e { out[url.path] = MoveCopy.size(url) ?? -1 }
        return out
    }

    private func claimed(_ b: Paths) -> MoveMarker? {
        if case .claimed(let m) = MoveMarker.look(MoveMarker.folder(id, in: b)) { return m }
        return nil
    }

    // MARK: Y9

    func testApplyNamesOnAMarkedCallIsRefused() async throws {
        let a = temp()
        let before = try marked(a)
        let lib = library(a)
        let bytes = try Data(contentsOf: a.callDirectory(id).appendingPathComponent(CallRecord.fileName))
        await pipeline(a, lib).applyNames(callID: id, names: ["B": "Sam Carter"], emails: ["B": "sam.carter@example.com"])
        XCTAssertEqual(try Data(contentsOf: a.callDirectory(id).appendingPathComponent(CallRecord.fileName)), bytes)
        XCTAssertFalse(lib.profiles.contains { $0.name == "Sam Carter" }, "nothing is learned from it")
        XCTAssertEqual(try CallRecord.load(from: a.callDirectory(id)).speakerNames, before.speakerNames)
    }

    final class Calls: LanguageModel, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                     purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
            lock.withLock { n += 1 }
            return try JSONDecoder().decode(Output.self, from: Data(#"{"commitments":[]}"#.utf8))
        }
        func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                      execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
    }

    func testTheCommitmentsRunnerSkipsAMarkedCall() async throws {
        let a = temp()
        try marked(a)
        let calls = Calls()
        _ = await CommitmentRunner(paths: a, finder: CommitmentFinder(llm: calls, ownerName: "Avery Webb"), since: .distantPast).run()
        XCTAssertEqual(calls.count, 0, "no request about a meeting that moves")
        XCTAssertFalse(((try? CommitmentBook.load(from: a.commitments))?.checked ?? []).contains(id))
        // The same call with no mark is read: the test sees a real run.
        var r = try CallRecord.load(from: a.callDirectory(id))
        r.moveTo = nil
        try r.save(to: a.callDirectory(id))
        _ = await CommitmentRunner(paths: a, finder: CommitmentFinder(llm: calls, ownerName: "Avery Webb"), since: .distantPast).run()
        XCTAssertGreaterThan(calls.count, 0)
    }

    func testRetentionSkipsAMarkedCall() throws {
        let a = temp(), c = temp()
        let r = try marked(a)
        _ = try writtenCall(in: c)
        let now = r.end.addingTimeInterval(40 * 86_400)
        Retention.sweep(audioRoot: a.audio, recordingsAfterDays: 35, now: now)
        Retention.sweep(audioRoot: c.audio, recordingsAfterDays: 35, now: now)
        for name in ["me.caf", "them.caf", "recording.m4a"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent(name).path), "\(name) of the marked call stays")
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.callDirectory(id).appendingPathComponent(name).path), "\(name) of a call with no mark goes")
        }
    }

    func testALinkAtTheCallFolderIsRefusedAndTheTargetStaysAsItWas() async throws {
        let a = temp(), b = temp(), outside = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let s = source(a, b)
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        let call = MoveMarker.folder(id, in: b).appendingPathComponent(MoveMarker.callFolder)
        try FileManager.default.createDirectory(at: outside.root, withIntermediateDirectories: true)
        let elsewhere = outside.root.appendingPathComponent("call")
        try FileManager.default.moveItem(at: call, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: call, withDestinationURL: elsewhere)
        let before = listing(outside.root), audio = listing(b.audio), voices = listing(b.voices)
        let intake = MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true })
        XCTAssertEqual(intake.run(), [])
        XCTAssertEqual(claimed(b)?.intake, .refused)
        XCTAssertEqual(listing(outside.root), before, "nothing is written through the link")
        XCTAssertEqual(listing(b.audio), audio)
        XCTAssertEqual(listing(b.voices), voices)
        let ended = await s.run(id)
        XCTAssertEqual(ended, .cancelled(.refusedNotWhole))
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo, "the meeting stays in A")
    }

    // MARK: Minor findings

    /// M3: the record and the chats are checked by their hash before the take-in, and a listed chat that cannot be
    /// read stops the step.
    func testAChatThatChangedInIncomingIsRefused() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        var chat = Chat(title: "About the call")
        chat.callID = id
        try ChatStore(directory: a.chats).save(chat)
        let s = source(a, b)
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        guard case .incoming(let m) = MoveMarker.look(MoveMarker.folder(id, in: b)),
              let f = m.files.first(where: { $0.path.hasPrefix(MoveMarker.chatsFolder + "/") }) else { return XCTFail("no chat in the move") }
        let url = MoveMarker.folder(id, in: b).appendingPathComponent(f.path)
        var data = try Data(contentsOf: url)
        let i = try XCTUnwrap(data.firstIndex(of: UInt8(ascii: "A")))
        data[i] = UInt8(ascii: "B")
        try data.write(to: url)
        let intake = MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true })
        XCTAssertEqual(intake.run(), [])
        XCTAssertEqual(claimed(b)?.intake, .refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.callDirectory(id).path))
    }

    /// M11: what the first profile normally removes itself (a part, a cancelled or refused folder) goes after a week
    /// in the target; a folder that waits or was taken in never does.
    func testOldLeftoversInIncomingGoAfterAWeek() throws {
        let b = temp()
        try b.ensureDirectories()
        let fm = FileManager.default
        try fm.createDirectory(at: b.incoming, withIntermediateDirectories: true)
        func folder(_ name: String, marker: String?, intake: MoveMarker.Intake? = nil, age: TimeInterval) throws {
            let dir = b.incoming.appendingPathComponent(name)
            try fm.createDirectory(at: dir.appendingPathComponent("call"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: dir.appendingPathComponent("call/me.caf"))
            if let marker {
                var m = MoveMarker(callID: name, from: "default", to: work, made: t0, token: "aaaa0001", files: [], ownerKeys: [])
                m.intake = intake
                try JSONEncoder.move.encode(m).write(to: dir.appendingPathComponent(marker))
                try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: dir.appendingPathComponent(marker).path)
            }
            try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: dir.path)
        }
        let week: TimeInterval = 8 * 86_400
        try folder("20261101-090000", marker: MoveMarker.cancelledName, age: week)
        try folder("20261101-091000", marker: MoveMarker.claimedName, intake: .refused, age: week)
        try folder("20261101-092000.aaaa0001.part", marker: nil, age: week)
        try folder("20261101-093000", marker: MoveMarker.fileName, age: week)
        try folder("20261101-094000", marker: MoveMarker.claimedName, intake: .taken, age: week)
        try folder("20261101-095000", marker: MoveMarker.claimedName, intake: .takingIn, age: week)
        try folder("20261101-096000", marker: MoveMarker.cancelledName, age: 86_400)
        let intake = MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true },
                                now: { [t0] in t0 })
        intake.cleanUp()
        let left = Set((try? fm.contentsOfDirectory(atPath: b.incoming.path)) ?? [])
        XCTAssertEqual(left, ["20261101-093000", "20261101-094000", "20261101-095000", "20261101-096000"])
    }

    /// M15: a call that waits to move is not "in work", and a missing key does not count it.
    func testAMarkedRecordedCallIsNotInWork() throws {
        var r = fullRecord()
        r.status = .recorded
        r.moveTo = work
        let status = WorkerStatus.make(records: [r], missing: [.transcription], backupFailed: 0, syncFailed: false, now: t0)
        XCTAssertEqual(status.inWork, 0)
        XCTAssertNil(status.failure)
    }

    /// M8: a marked call keeps its record: the catch-up of summaries and the refresh of labels do not write it.
    func testTheCatchUpDoesNotWriteAMarkedCall() async throws {
        let a = temp()
        var r = try marked(a)
        r.tags = ["Budget"]
        r.tagsSetByOwner = nil
        try r.save(to: a.callDirectory(id))
        let bytes = try Data(contentsOf: a.callDirectory(id).appendingPathComponent(CallRecord.fileName))
        _ = await pipeline(a, library(a)).backfill(id)
        _ = await pipeline(a, library(a)).refreshLabels()
        XCTAssertEqual(try Data(contentsOf: a.callDirectory(id).appendingPathComponent(CallRecord.fileName)), bytes)
        try FileManager.default.removeItem(at: Recording.url(in: a.callDirectory(id)))
        XCTAssertEqual(Recording.missing(audioRoot: a.audio, hasBackup: { _ in false }), [], "no recording is made in a folder that moves")
    }
}
