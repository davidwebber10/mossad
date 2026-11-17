import XCTest
@testable import MossadCore

/// The third review of the move engine: the kept reason of a move that ended (N3), one start at a time (M1), and the
/// part's names (M2).
final class MoveReviewThreeTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveReviewThreeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    private func source(_ a: Paths, target: @escaping @Sendable () -> MoveRules.TargetPlace) -> MoveSource {
        let lib = library(a)
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in }, backup: { _ in true },
                                          removeFolder: { i, to in await pipeline.removeMoved(callID: i, target: to) })
        return MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                           target: { _ in target() }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                           now: { [t0] in t0 }))
    }

    final class Place: @unchecked Sendable {
        var value: MoveRules.TargetPlace
        init(_ v: MoveRules.TargetPlace) { value = v }
    }

    /// N3: a move that a refusal or a gone target ended keeps its reason until the window app has shown it; another
    /// run (a worker's) never deletes it; the owner's own Cancel keeps none.
    func testTheReasonOfAnEndedMoveIsKeptUntilShown() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let place = Place(.paths(b))
        let s = source(a) { place.value }
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        place.value = .gone
        let end = await s.run(id)
        XCTAssertEqual(end, .cancelled(.targetGone))
        XCTAssertNil(MoveOut.load(id, paths: a))
        XCTAssertEqual(MoveEnded.load(id, paths: a)?.why, .targetGone)
        _ = await s.runAll()
        XCTAssertEqual(MoveEnded.all(a).map(\.callID), [id], "a later run keeps it")
        XCTAssertFalse(MoveOut.leftIDs(a).contains(id), "the id did not leave")
        MoveEnded.shown(id, paths: a)
        XCTAssertTrue(MoveEnded.all(a).isEmpty)

        place.value = .paths(b)
        _ = await s.start(id, to: work)
        let cancelled = await s.cancelMove(id)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(MoveEnded.all(a).isEmpty, "the owner's own Cancel keeps no reason")
    }

    /// M1: two starts of one id at once save one ledger.
    func testTwoStartsAtOnceStartOneMove() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let s = source(a) { .paths(b) }
        let callID = id, to = work
        let answers = await withTaskGroup(of: MoveSource.Start.self) { group in
            for _ in 0..<2 { group.addTask { await s.start(callID, to: to) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(answers.filter { $0 == .started }.count, 1, "\(answers)")
    }

    /// M2: the copy and the publish refuse an id or a token that cannot be a path component, and never make the hidden name.
    func testThePartRefusesABadIDOrToken() throws {
        let b = temp()
        try b.ensureDirectories()
        XCTAssertThrowsError(try MoveCopy.publish(id, token: "not-a-token", incoming: b.incoming))
        XCTAssertThrowsError(try MoveCopy.publish("../x", token: "abc123", incoming: b.incoming))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.incoming.appendingPathComponent(MovePaths.notAnID + MoveMarker.partSuffix).path))
    }

    /// N5: the people who go are checked again at the delete. A person who got another meeting since the list was
    /// decided stays, with the coach's notes on them.
    func testAPersonWithANewMeetingSinceTheListStays() async throws {
        let a = temp()
        let r = try writtenCall(in: a)
        let lib = library(a)
        let sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: r.start + 60)
        try lib.identity!.people.replaceAll([sam])
        var out = MoveOut(callID: id, to: work, started: t0, token: "abcd0001")
        out.state = .removing
        out.removed = ["voices"]
        out.people = ["p-sam"]
        // A new meeting names Sam after the list was saved.
        var later = r
        later.id = "20261109-100000"
        try FileManager.default.createDirectory(at: a.callDirectory(later.id), withIntermediateDirectories: true)
        try later.save(to: a.callDirectory(later.id))
        final class Forgot: @unchecked Sendable { var ids: [String] = [] }
        let forgot = Forgot()
        let actions = MoveRemoval.Actions(forgetPersona: { forgot.ids.append($0) }, coach: { _ in }, stopShares: { _ in }, backup: { _ in true },
                                          removeFolder: { _, _ in true })
        let done = try await MoveRemoval.run(.people, out: out, paths: a, library: lib, ownerName: "Avery Webb", actions: actions, now: t0)
        XCTAssertTrue(done)
        XCTAssertTrue(lib.identity!.people.people.contains { $0.id.rawValue == "p-sam" && $0.isLive }, "Sam stays")
        XCTAssertTrue(forgot.ids.isEmpty, "the read of a person who stays is kept")
    }
}
