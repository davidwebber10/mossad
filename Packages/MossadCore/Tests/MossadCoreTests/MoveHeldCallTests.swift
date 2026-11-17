import XCTest
@testable import MossadCore

/// A call that the owner marked for another profile during its recording and that waits here (its move was refused,
/// or its profile is gone): "Move to" another profile changes the mark in one write, and "Process here" takes it off.
final class MoveHeldCallTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let gone = "9f9f9f9f"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveHeldCallTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func source(_ a: Paths, target: MoveRules.TargetPlace) -> (MoveSource, Pipeline, FakeTranscriber) {
        let lib = VoiceLibrary(directory: a.voices)
        lib.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        let transcriber = FakeTranscriber()
        let pipeline = Pipeline(paths: a, transcriber: transcriber, library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in },
                                          backup: { _ in true }, removeFolder: { id, to in await pipeline.removeMoved(callID: id, target: to) })
        let s = MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                            target: { _ in target }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                            now: { [t0] in t0 }))
        return (s, pipeline, transcriber)
    }

    private func heldCall(_ a: Paths, status: CallStatus = .recorded) throws -> URL {
        try a.ensureDirectories()
        let dir = a.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400)])
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 1800, status: status)
        r.moveTo = gone
        try r.save(to: dir)
        return dir
    }

    func testAHeldCallMovesToAnotherProfile() async throws {
        let a = temp(), b = temp()
        try b.ensureDirectories()
        let dir = try heldCall(a)
        let (s, pipeline, transcriber) = source(a, target: .paths(b))
        let started = await s.start(id, to: work, afterCall: true)
        XCTAssertEqual(started, .started)
        XCTAssertEqual(try CallRecord.load(from: dir).moveTo, work)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.afterCall, true)
        await pipeline.runPending()
        XCTAssertTrue(transcriber.calls.isEmpty, "the call is never sent from here in between")
    }

    /// Only a call marked during its recording changes its mark; a written meeting whose move waits keeps its target.
    func testAMarkChangesOnlyForACallMarkedDuringItsRecording() async throws {
        let a = temp(), b = temp()
        try b.ensureDirectories()
        let dir = try heldCall(a)
        let (s, _, _) = source(a, target: .paths(b))
        let refused = await s.start(id, to: work)
        XCTAssertNotEqual(refused, .started)
        XCTAssertEqual(try CallRecord.load(from: dir).moveTo, gone)
    }

    func testTheMarkChangesInOneWrite() async throws {
        let a = temp()
        let dir = try heldCall(a)
        let (_, pipeline, _) = source(a, target: .unknown)
        let changed = await pipeline.setMoveTarget(callID: id, work, replacing: gone)
        XCTAssertTrue(changed)
        XCTAssertEqual(try CallRecord.load(from: dir).moveTo, work)
        // A mark that is not the one named stays.
        let other = await pipeline.setMoveTarget(callID: id, "5e6f7a8b", replacing: gone)
        XCTAssertFalse(other)
        XCTAssertEqual(try CallRecord.load(from: dir).moveTo, work)
    }

    func testProcessHereTakesTheMarkOff() async throws {
        let a = temp()
        let dir = try heldCall(a)
        let (_, pipeline, _) = source(a, target: .gone)
        let off = await pipeline.setMoveTarget(callID: id, nil)
        XCTAssertTrue(off)
        XCTAssertNil(try CallRecord.load(from: dir).moveTo)
    }
}
