import XCTest
@testable import MossadCore

/// Review N2, the target's side: a take-in that fails after the file check counts its tries in the marker, waits
/// longer after each, logs once for each change, and after the last wait says where it waits, so the first profile's
/// row can say it. Also the cancel whose mark cannot come off.
final class MoveTakeInRetryTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func set(_ d: Date) { lock.withLock { t = d } }
    }

    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ v: Bool) { on = v }
        var value: Bool { lock.withLock { on } }
        func set(_ v: Bool) { lock.withLock { on = v } }
    }

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveTakeInRetryTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    private func source(_ a: Paths, place: @escaping @Sendable () -> MoveRules.TargetPlace, clock: Clock) -> MoveSource {
        let lib = library(a)
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in },
                                          backup: { _ in true }, removeFolder: { id, to in await pipeline.removeMoved(callID: id, target: to) })
        return MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                           target: { _ in place() }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                           now: { clock.now }))
    }

    private func logLines(_ dir: URL, _ text: String) throws -> Int {
        Log.flush()
        let all = (try? String(contentsOf: dir.appendingPathComponent("mossad.log"), encoding: .utf8)) ?? ""
        return all.components(separatedBy: "\n").filter { $0.contains(text) }.count
    }

    func testATakeInThatFailsAfterTheCheckWaitsLongerAndSaysWhere() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let logs = temp().root
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let before = Log.directory, writes = Log.writesFile
        Log.directory = logs
        Log.writesFile = true
        defer { Log.directory = before; Log.writesFile = writes }

        let clock = Clock(t0)
        let s = source(a, place: { .paths(b) }, clock: clock)
        _ = await s.start(id, to: work)
        let waits = await s.run(id)
        XCTAssertEqual(waits, .waiting)
        // The meeting's own folder in B cannot be synced: the part after the check fails each time.
        let broken = Switch(true), dir = b.callDirectory(id).standardizedFileURL.path
        let intake = MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true },
                                sync: { url in
                                    if broken.value, url.standardizedFileURL.path == dir { throw CocoaError(.fileWriteUnknown) }
                                    try MoveFiles.fullSync(url)
                                }, now: { clock.now })
        func marker() -> MoveMarker? {
            if case .claimed(let m) = MoveMarker.look(MoveMarker.folder(id, in: b)) { return m }
            return nil
        }
        XCTAssertEqual(intake.run(), [])
        XCTAssertEqual(marker()?.waits, .record)
        XCTAssertEqual(marker()?.tries, 1)
        XCTAssertEqual(marker()?.intake, .takingIn)
        // After one try the next look tries; then 1, 5, and 30 minutes.
        intake.run()
        XCTAssertEqual(marker()?.tries, 2)
        intake.run()
        XCTAssertEqual(marker()?.tries, 2, "not due before a minute")
        clock.set(t0.addingTimeInterval(61))
        intake.run()
        XCTAssertEqual(marker()?.tries, 3)
        // A has nothing to say before the last wait step.
        _ = await s.run(id)
        XCTAssertNil(MoveOut.load(id, paths: a)?.targetWaits)
        clock.set(t0.addingTimeInterval(61 + 301))
        intake.run()
        XCTAssertEqual(marker()?.tries, 4)
        XCTAssertEqual(try logLines(logs, "the take-in of \(id) waits"), 1, "one line for one change of where it waits")
        _ = await s.run(id)
        let out = try XCTUnwrap(MoveOut.load(id, paths: a))
        XCTAssertEqual(out.state, .waiting, "A keeps its meeting")
        XCTAssertEqual(out.targetWaits, .record)
        let row = MoveShow.row(try CallRecord.load(from: a.callDirectory(id)), move: out, name: "Personal", copied: nil, reach: .open,
                               held: nil, now: clock.now)
        XCTAssertEqual(row?.text, "“Personal” took the meeting but has not finished: it cannot save the meeting here yet. It tries again.")
        XCTAssertEqual(row?.cancels, false)
        // It keeps trying at the last wait, and goes on once the cause is gone.
        broken.set(false)
        clock.set(t0.addingTimeInterval(61 + 301 + 1801))
        XCTAssertEqual(intake.run(), [id])
        XCTAssertNil(marker()?.waits)
        let moved = await s.run(id)
        XCTAssertEqual(moved, .moved(to: work))
    }

    func testEveryKindHasItsWords() {
        for kind in MoveMarker.TakeInWait.allCases {
            let text = MoveWords.notFinished("Work", kind)
            XCTAssertTrue(text.hasPrefix("“Work” took the meeting but has not finished: "), text)
            XCTAssertFalse(text.contains("Sam"), text)
        }
        XCTAssertTrue(MoveRetry.gaveUp(tries: MoveRetry.waits.count))
        XCTAssertFalse(MoveRetry.gaveUp(tries: MoveRetry.waits.count - 1))
    }

    func testACancelWhoseMarkCannotComeOffWaitsLonger() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let clock = Clock(t0)
        let gone = Switch(false)
        let s = source(a, place: { gone.value ? .gone : .paths(b) }, clock: clock)
        _ = await s.start(id, to: work)
        let dir = a.callDirectory(id)
        // The record cannot be written: the mark cannot come off.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        gone.set(true)
        let first = await s.run(id)
        XCTAssertEqual(first, .waiting)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.tries, 1)
        _ = await s.run(id)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.tries, 2)
        _ = await s.run(id)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.tries, 2, "not due before a minute")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        clock.set(t0.addingTimeInterval(61))
        let ended = await s.run(id)
        XCTAssertEqual(ended, .cancelled(.targetGone))
        XCTAssertNil(try CallRecord.load(from: dir).moveTo)
    }
}
