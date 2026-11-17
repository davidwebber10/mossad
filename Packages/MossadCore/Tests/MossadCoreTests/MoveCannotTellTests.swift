import XCTest
@testable import MossadCore

/// Review N1 and its class: "cannot tell" is never read as "no". A marker that does not read, a listing that fails, a
/// book that does not read, a ledger that does not read, and a record of another meeting that does not read each wait
/// or keep, and never end a move, delete a ledger, or delete a person.
final class MoveCannotTellTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let mine = "aaaa1111", theirs = "cccc3333"

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveCannotTellTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func ledger(_ state: MoveOut.State) -> MoveOut {
        var out = MoveOut(callID: id, to: work, started: t0, token: mine)
        out.state = state
        return out
    }

    private func marker() -> MoveMarker {
        MoveMarker(callID: id, from: "default", to: work, made: t0, token: mine,
                   files: [.init(path: "call/call.json", size: 120, sha256: String(repeating: "a", count: 64))], ownerKeys: ["me:A"])
    }

    /// N1: a cancel never ends on a marker that it could not read: B may have claimed it in that moment.
    func testACancelWaitsOnAMarkerThatDoesNotRead() {
        for target in [MovePlan.Target.live, .gone] {
            XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .unknown, part: false, target: target), .wait, "\(target)")
            XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .unknown, part: true, target: target), .wait, "\(target)")
        }
    }

    /// N1: B's claim between the test of `move.json` and its read: the look reads `claimed.json` again.
    func testAClaimBetweenTheTestAndTheReadIsSeen() throws {
        let folder = MoveMarker.folder(id, in: temp())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try marker().save(in: folder, claimed: false)
        let seen = MoveMarker.look(folder, beforeRead: { XCTAssertTrue(MoveMarker.claim(folder)) })
        XCTAssertEqual(seen, .claimed(marker()))
    }

    /// A `move.json` that is there and does not read is not known, also after the second test.
    func testAMarkerThatDoesNotReadIsNotKnown() throws {
        let folder = MoveMarker.folder(id, in: temp())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent(MoveMarker.fileName))
        XCTAssertEqual(MoveMarker.look(folder), .unknown)
    }

    /// M10: the owner's Cancel with a ledger that does not read changes nothing and says it cannot tell.
    func testCancelWithALedgerThatDoesNotReadIsNotCancelled() async throws {
        let a = temp()
        try a.ensureDirectories()
        try FileManager.default.createDirectory(at: a.moves, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: MoveOut.url(id, paths: a))
        let s = MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline(a), library: library(a), ownerName: { "Avery Webb" },
                                            target: { _ in .unknown }, fetch: { _, _ in nil }, usage: { _ in [] },
                                            actions: MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in },
                                                                         backup: { _ in true }, removeFolder: { _, _ in false })))
        let answer = await s.cancelMove(id)
        XCTAssertEqual(answer, .unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: MoveOut.url(id, paths: a).path), "the ledger stays")
    }

    /// M4: B's listing of `Audio` that fails is not "empty": the target waits.
    func testATargetWaitsWhenItsAudioDoesNotList() {
        XCTAssertNil(MoveIntake.audioNames(URL(fileURLWithPath: "/nonexistent/made-up/Audio")))
        XCTAssertEqual(MoveIntake.audioNames(FileManager.default.temporaryDirectory.appendingPathComponent("MoveCannotTellTests-none-\(UUID())"),
                                             missingIsEmpty: true), [])
    }

    /// M6: a share book that does not read is not "no links": the step does not end.
    func testASharesStepWaitsOnABookThatDoesNotRead() throws {
        let a = temp()
        try a.ensureDirectories()
        try FileManager.default.createDirectory(at: a.shares, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: a.shares.appendingPathComponent(ShareBook.fileName))
        XCTAssertFalse(MoveRemoval.sharesStopped(id, paths: a))
    }

    /// A record of another meeting that does not read may be a meeting of that person: the person stays.
    func testAPersonStaysWhenAnotherRecordDoesNotRead() throws {
        let a = temp()
        try a.ensureDirectories()
        let other = a.callDirectory("20261102-100000")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: other.appendingPathComponent(CallRecord.fileName))
        XCTAssertNil(MoveRemoval.otherRecords(excluding: id, paths: a), "cannot tell")
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    private func pipeline(_ a: Paths) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: library(a), embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
    }
}
