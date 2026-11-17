import XCTest
@testable import MossadCore

/// Each removal step ends only when it was done, the person who goes leaves no coach note at any stop, and the folder
/// goes only through `Pipeline.removeMoved` for its own marked id.
final class MoveRemovalStepTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveRemovalStepTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ a: Paths, identity: Bool = true) -> VoiceLibrary {
        let l = VoiceLibrary(directory: a.voices)
        if identity { l.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices)) }
        return l
    }

    private func pipeline(_ a: Paths) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: library(a), embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: nil, notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
    }

    /// A with the marked meeting, the voice it taught (which made "Sam Carter"), the coach's note on that person, a
    /// share link, and its words in the books.
    private func world() throws -> Paths {
        let a = temp()
        var r = try writtenCall(in: a)
        r.moveTo = work
        try r.save(to: a.callDirectory(id))
        let lib = library(a)
        try lib.add(r.speakerEmbeddings["them:A"]!, to: "Sam Carter",
                    source: VoiceSampleSource(callID: id, speakerKey: "them:A", recorded: r.start, seconds: 30, quality: 0.8, origin: .ownerNamed))
        var coach = CoachProfile()
        coach.people["Sam Carter"] = CoachPerson(note: "Sam Carter likes the zebra plan", calls: 1, lastSeen: t0)
        coach.history = [CoachHistoryEntry(callID: id, title: "Zebra budget", date: t0, headline: "About the zebra crossing")]
        try coach.save(to: a.coach)
        var shares = ShareBook()
        shares.links = [MeetingLink(token: "tok", callID: id, title: "Shared", options: ShareOptions(), created: t0)]
        try shares.save(to: a.shares)
        var tasks = CommitmentBook()
        tasks.items = [Commitment(text: "Send the zebra budget", to: "Sam Carter", callID: id, callTitle: "Zebra budget", madeAt: t0, due: nil, created: t0)]
        try tasks.save(to: a.commitments)
        return a
    }

    private func actions(_ a: Paths, _ p: Pipeline, stop: @escaping @Sendable (String) throws -> Void = { _ in },
                         shares: Bool = true, backup: Bool = true) -> MoveRemoval.Actions {
        MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            var c = try CoachProfile.load(from: a.coach)
            change(&c)
            try c.save(to: a.coach)
        }, stopShares: { callID in
            guard shares else { return }
            var book = ShareBook.load(from: a.shares)
            book.markStopping(callID: callID)
            try? book.save(to: a.shares)
        }, backup: { r in
            guard backup else { return false }
            CloudArchive.rememberDeletes(of: r, paths: a)
            return true
        }, removeFolder: { id, to in await p.removeMoved(callID: id, target: to, stop: stop) })
    }

    private func ledger(_ a: Paths) throws -> MoveOut {
        var out = MoveOut(callID: id, to: work, started: t0)
        out.state = .removing
        try out.save(a)
        return out
    }

    private func coachText(_ a: Paths) -> String { (try? String(contentsOf: a.coach.appendingPathComponent(CoachProfile.fileName), encoding: .utf8)) ?? "" }

    /// C4 and the order of every step: at each stop inside a step, that step is not in the ledger; the next run ends
    /// with no note on the person who went, no sample, no person, no word of the call, and every share link stopping.
    func testAStopAtAnyPointOfAnyStepEndsWithNothingLeft() async throws {
        let counter = StopAt()
        do {
            let a = try world()
            var out = try ledger(a)
            let p = pipeline(a)
            try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, p, stop: counter.step),
                                          now: t0, stop: counter.step)
            XCTAssertNil(out.nextStep)
        }
        let names = counter.seen
        for needed in ["people: the coach forgets", "people: the person", "voices: forget", "books: the points", "coach: the runner", "folder: out of Audio"] {
            XCTAssertTrue(names.contains { $0.hasPrefix(needed) }, "no stop at \(needed): \(names)")
        }
        for n in 0..<names.count {
            let a = try world()
            var out = try ledger(a)
            let p = pipeline(a)
            let stop = StopAt(n)
            do {
                try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, p, stop: stop.step),
                                              now: t0, stop: stop.step)
            } catch is MoveStop {}
            let at = stop.seen.last ?? ""
            let saved = try XCTUnwrap(MoveOut.load(id, paths: a))
            if let step = MoveOut.Step.allCases.first(where: { at.hasPrefix("\($0.rawValue):") }) {
                XCTAssertFalse(saved.removed.contains(step.rawValue), "stop \(n) (\(at)): the step was saved before it ended")
            }
            if !saved.removed.contains(MoveOut.Step.folder.rawValue), at != "folder ended, before its save" {
                XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent(CallRecord.fileName).path)
                              || FileManager.default.fileExists(atPath: a.moves.appendingPathComponent("\(id).removing/\(CallRecord.fileName)").path),
                              "stop \(n) (\(at)): the record went before the folder step")
            }
            var next = saved
            let q = pipeline(a)
            try await MoveRemoval.advance(&next, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, q), now: t0)
            XCTAssertNil(next.nextStep, "stop \(n) (\(at))")
            let coach = coachText(a)
            XCTAssertFalse(coach.contains("Sam Carter likes"), "stop \(n) (\(at)): the coach's note on the person stayed")
            XCTAssertFalse(coach.lowercased().contains("zebra"), "stop \(n) (\(at))")
            let lib = library(a)
            XCTAssertFalse(lib.profiles.contains { $0.name == "Sam Carter" }, "stop \(n) (\(at)): the voice stayed")
            XCTAssertFalse(lib.identity?.people.people.contains { $0.isLive && $0.displayName == "Sam Carter" } ?? true, "stop \(n) (\(at))")
            XCTAssertTrue(ShareBook.load(from: a.shares).links.allSatisfy { $0.stopping == true }, "stop \(n) (\(at))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path), "stop \(n) (\(at))")
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.moves.appendingPathComponent("\(id).removing").path), "stop \(n) (\(at))")
        }
    }

    /// I6: with no identity the voice and people steps wait; a share link with no saved stop and a backup that was
    /// neither deleted nor remembered keep their steps open.
    func testAStepThatCouldNotBeDoneIsNeverDone() async throws {
        let a = try world()
        var out = try ledger(a)
        let p = pipeline(a)
        try await MoveRemoval.advance(&out, paths: a, library: library(a, identity: false), ownerName: "Avery Webb", actions: actions(a, p), now: t0)
        XCTAssertEqual(out.removed, [], "no identity: the voices step waits")
        XCTAssertEqual(MoveOut.load(id, paths: a)?.removed, [])

        try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, p, shares: false), now: t0)
        XCTAssertEqual(out.nextStep, .shares, "a live share link with no saved stop")
        try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, p, backup: false), now: t0)
        XCTAssertEqual(out.nextStep, .backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb", actions: actions(a, p), now: t0)
        XCTAssertNil(out.nextStep)
    }

    /// I5: `removeMoved` acts only on a plain id whose folder in `Audio` holds a readable record of that id, marked
    /// for that target.
    func testRemoveMovedTakesOnlyItsOwnMarkedFolder() async throws {
        let a = try world()
        let p = pipeline(a)
        var other = try writtenCall(in: a, id: "20261102-100000")
        other.moveTo = nil
        try other.save(to: a.callDirectory(other.id))
        for hostile in ["", ".", "..", "a/b", "../x", "/abs", "../Meetings", ".hidden", String(repeating: "9", count: 300)] {
            let removed = await p.removeMoved(callID: hostile, target: work)
            XCTAssertFalse(removed, "\(hostile)")
        }
        let wrongTarget = await p.removeMoved(callID: id, target: "5e6f7a8b")
        XCTAssertFalse(wrongTarget)
        let notMarked = await p.removeMoved(callID: other.id, target: work)
        XCTAssertFalse(notMarked)
        try Data("not a record".utf8).write(to: a.callDirectory(other.id).appendingPathComponent(CallRecord.fileName))
        let unreadable = await p.removeMoved(callID: other.id, target: work)
        XCTAssertFalse(unreadable, "a record that does not read")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: a.audio.path)), [id, other.id])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: a.meetings.path).isEmpty)
        let removed = await p.removeMoved(callID: id, target: work)
        XCTAssertTrue(removed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.audio.path), [other.id])
    }

    func testTheIDCheck() {
        for good in ["20261101-100000", "20261101-100000-moved", "1a2b3c4d", "default", UUID().uuidString] { XCTAssertTrue(MovePaths.isID(good), good) }
        for bad in ["", ".", "..", "a/b", "../x", "/abs", ".hidden", "a b", "a\u{0}b", String(repeating: "9", count: 129)] {
            XCTAssertFalse(MovePaths.isID(bad), bad)
        }
        XCTAssertTrue(MovePaths.isToken(MoveOut.newToken()))
        XCTAssertFalse(MovePaths.isToken("../x"))
        let p = Paths(root: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertNotEqual(MoveMarker.folder("", in: p), p.incoming)
        XCTAssertNotEqual(MoveMarker.folder("..", in: p).standardizedFileURL, p.root)
        XCTAssertEqual(MoveOut.load("../x", paths: p), nil)
    }
}
