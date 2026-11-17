import Darwin
import XCTest
@testable import MossadCore

/// A refusal at any point of the take-in leaves the target as it was; the arrived record is marked until `taken`; a
/// rename that keeps failing ends in a refusal; a sync that fails stops the step.
final class MoveIntakeStepTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let token = "token-a"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveIntakeStepTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    /// A and B; B already knows another person, so its files are there before the take-in.
    private func arrive() throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let lib = library(b)
        try lib.add([0.9, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1], to: "Avery Lane",
                    source: VoiceSampleSource(callID: "20261001-090000", speakerKey: "them:A", recorded: t0, seconds: 30, quality: 0.8, origin: .ownerNamed))
        var chat = Chat(title: "Another meeting")
        chat.callID = "20261001-090000"
        try ChatStore(directory: b.chats).save(chat)
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        _ = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0)
        try MoveCopy.publish(id, token: token, incoming: b.incoming)
        return (a, b)
    }

    private func library(_ b: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: b.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices))
        return l
    }

    private func intake(_ b: Paths, stop: @escaping @Sendable (String) throws -> Void = { _ in },
                        rename: @escaping @Sendable (String, String) -> Int32 = MoveFiles.exclusive,
                        sync: @escaping @Sendable (URL) throws -> Void = MoveFiles.fullSync) -> MoveIntake {
        MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true }, stop: stop,
                   rename: rename, sync: sync)
    }

    private func claimed(_ b: Paths) -> MoveMarker? {
        if case .claimed(let m) = MoveMarker.look(MoveMarker.folder(id, in: b)) { return m }
        return nil
    }

    /// The files of B that a take-in may change, by their hashes; a file that is not there is "none".
    private func state(_ b: Paths) -> [String: String] {
        var out: [String: String] = [:]
        for f in [b.people.appendingPathComponent("people.json"), b.voices.appendingPathComponent("voices.json"),
                  b.voices.appendingPathComponent("samples.json")] {
            out[f.lastPathComponent] = (try? FileHash.sha256(of: f)) ?? "none"
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: b.chats.path)) ?? [] {
            out["Chats/" + name] = (try? FileHash.sha256(of: b.chats.appendingPathComponent(name))) ?? "?"
        }
        out["Audio"] = ((try? FileManager.default.contentsOfDirectory(atPath: b.audio.path)) ?? []).sorted().joined(separator: ",")
        return out
    }

    private static let otherVolume: @Sendable (String, String) -> Int32 = { from, to in
        to.contains("/Audio/") ? EXDEV : MoveFiles.exclusive(from, to)
    }

    /// C3: a refusal after a stop at any point of the take-in (the rename into `Audio` meets another volume) leaves B's
    /// people, voices, samples, chats, and `Audio` byte for byte as they were.
    func testARefusalAtAnyPointLeavesTheTargetAsItWas() throws {
        let counter = StopAt()
        do {
            let (_, b) = try arrive()
            _ = intake(b, stop: counter.step).run()
            XCTAssertEqual(claimed(b)?.intake, .taken)
        }
        XCTAssertGreaterThan(counter.seen.count, 8, "\(counter.seen)")
        for n in 0..<counter.seen.count {
            let (_, b) = try arrive()
            let before = state(b)
            let stop = StopAt(n)
            _ = intake(b, stop: stop.step).run()
            let at = stop.seen.last ?? ""
            for _ in 0..<12 { _ = intake(b, rename: Self.otherVolume).run() }
            let m = try XCTUnwrap(claimed(b), "stop \(n) (\(at))")
            if m.intake == .refused {
                XCTAssertEqual(state(b), before, "stop \(n) (\(at)): the refusal left something of the take-in")
            } else {
                XCTAssertEqual(m.intake, .taken, "stop \(n) (\(at))")
            }
        }
    }

    /// C3 c and I3: a meeting with the chosen id comes into `Audio` between the two halves: the meeting arrives under
    /// the other name, and the one that was there is untouched.
    func testAnIDTakenBetweenTheHalvesGetsTheOtherName() throws {
        let (_, b) = try arrive()
        let stop = StopAt(0)
        let i = intake(b)
        XCTAssertEqual(i.step(id), .claim)
        XCTAssertEqual(i.step(id), .decide)
        XCTAssertEqual(i.step(id), .takeIn(as: id))
        // The first half is done: the call folder in `Incoming` has its arrival record.
        XCTAssertTrue(FileManager.default.fileExists(atPath: MoveMarker.folder(id, in: b).appendingPathComponent("call/call.json").path))
        let other = b.callDirectory(id)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: other.appendingPathComponent("note.txt"))
        _ = stop
        for _ in 0..<12 { _ = intake(b).run() }
        let m = try XCTUnwrap(claimed(b))
        XCTAssertEqual(m.intake, .taken)
        XCTAssertEqual(m.finalID, id + "-moved")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), ["note.txt"])
        XCTAssertEqual(try CallRecord.load(from: b.callDirectory(id + "-moved")).id, id + "-moved")
        XCTAssertEqual(ChatStore(directory: b.chats).all().filter { $0.callID == id + "-moved" }.count, 1)
    }

    /// I2: until `taken` the record in B's `Audio` is marked, so no pipeline, queue, or runner of B touches it.
    func testTheArrivedRecordIsMarkedUntilTaken() throws {
        let (_, b) = try arrive()
        let i = intake(b)
        var sawInAudio = false
        for _ in 0..<12 {
            let step = i.step(id)
            if let r = try? CallRecord.load(from: b.callDirectory(id)) {
                if claimed(b)?.intake != .taken {
                    sawInAudio = true
                    XCTAssertEqual(r.moveTo, work, "in Audio before taken, after \(step)")
                    XCTAssertFalse(ProcessingQueue(paths: b).pending(now: Date()).contains { $0.id == id })
                }
            }
            if claimed(b)?.intake == .taken { break }
        }
        XCTAssertTrue(sawInAudio)
        XCTAssertEqual(claimed(b)?.intake, .taken)
        XCTAssertNil(try CallRecord.load(from: b.callDirectory(id)).moveTo, "the mark goes with taken")
    }

    /// I3: a rename into `Audio` that keeps failing ends in a refusal after a bounded number of tries; B is as before.
    func testARenameThatKeepsFailingEndsInARefusal() throws {
        let (_, b) = try arrive()
        let before = state(b)
        let failing: @Sendable (String, String) -> Int32 = { from, to in to.contains("/Audio/") ? EACCES : MoveFiles.exclusive(from, to) }
        for _ in 0..<(MoveIntake.maxTries + 2) { _ = intake(b, rename: failing).run() }
        XCTAssertEqual(claimed(b)?.intake, .refused)
        XCTAssertEqual(state(b), before)
    }

    /// I8: a sync that fails before `taken` stops the step: no `taken` on files that may not be on the disk.
    func testASyncThatFailsStopsTheStep() throws {
        let (_, b) = try arrive()
        struct NoSync: Error {}
        // Only the sync of the meeting in `Audio` fails: the step before `taken`.
        _ = intake(b, sync: { url in
            if url.path.contains("/Audio/") { throw NoSync() }
            try MoveFiles.fullSync(url)
        }).run()
        XCTAssertNotEqual(claimed(b)?.intake, .taken)
        _ = intake(b).run()
        XCTAssertEqual(claimed(b)?.intake, .taken)
    }

    /// The first reordering of the review: `taken` with no check of the files. A file changed in B's `Audio` before
    /// the check gives a refusal, and B is as before.
    func testAFileChangedBeforeTheCheckIsRefused() throws {
        let (_, b) = try arrive()
        let before = state(b)
        let i = intake(b)
        var changed = false
        for _ in 0..<12 {
            _ = i.step(id)
            if !changed, FileManager.default.fileExists(atPath: b.callDirectory(id).appendingPathComponent("me.caf").path), claimed(b)?.intake == .takingIn {
                try Data(repeating: 1, count: 4096).write(to: b.callDirectory(id).appendingPathComponent("me.caf"))
                changed = true
            }
            if let m = claimed(b), m.intake == .taken || m.intake == .refused { break }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(claimed(b)?.intake, .refused)
        XCTAssertEqual(state(b), before)
    }

    /// A chat link of the meeting in any form follows the id it gets here.
    func testEveryLinkOfTheCallFollowsTheNewID() throws {
        let text = "See mossad://call/\(id) and [a](mossad://call/\(id)?t=4), mossad://call/\(id). Not mossad://call/\(id)9."
        let out = MoveIntake.relink(text, from: id, to: id + "-moved")
        XCTAssertEqual(out, "See mossad://call/\(id)-moved and [a](mossad://call/\(id)-moved?t=4), mossad://call/\(id)-moved. Not mossad://call/\(id)9.")
    }
}
