import XCTest
@testable import MossadCore

final class MoveRemovalTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveRemovalTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func allText(_ dir: URL) -> String {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return "" }
        var out = ""
        for case let url as URL in e where url.pathExtension == "json" || url.pathExtension == "md" {
            out += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return out
    }

    private func library(_ a: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: a.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        return l
    }

    /// A with the meeting, what it taught, and its words in each book; B holding the same meeting (taken).
    private func world() throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        let r = try writtenCall(in: a)
        let lib = library(a)
        for key in ["them:A"] {
            try lib.add(r.speakerEmbeddings[key]!, to: r.speakerNames[key]!,
                        source: VoiceSampleSource(callID: id, speakerKey: key, recorded: r.start, seconds: 30, quality: 0.8, origin: .ownerNamed))
        }
        var tasks = CommitmentBook()
        tasks.items = [Commitment(text: "Send the zebra budget", to: "Sam Carter", callID: id, callTitle: "Zebra budget", madeAt: t0, due: nil, created: t0)]
        try tasks.save(to: a.commitments)
        _ = try NextTimeBook.change(in: a.nextTime) { book in
            var p = NextTimePoint(text: "Hiring", personID: "p-1", personName: "Sam Carter", rank: 1, created: self.t0)
            p.mentions = [.init(callID: self.id, at: 4, quote: "the zebra crossing is closed", date: self.t0)]
            book.points = [p]
        }
        var coach = CoachProfile()
        coach.history = [CoachHistoryEntry(callID: id, title: "Zebra budget", date: t0, headline: "About the zebra crossing")]
        try coach.save(to: a.coach)
        // B holds the meeting (the copy that the target took in).
        try FileManager.default.createDirectory(at: b.callDirectory(id), withIntermediateDirectories: true)
        try r.save(to: b.callDirectory(id))
        return (a, b)
    }

    private func actions(_ a: Paths, folder: @escaping @Sendable (String) async -> Bool) -> MoveRemoval.Actions {
        MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            var p = (try? CoachProfile.load(from: a.coach)) ?? CoachProfile()
            change(&p)
            try p.save(to: a.coach)
        }, stopShares: { callID in
            var book = ShareBook.load(from: a.shares)
            book.markStopping(callID: callID)
            try? book.save(to: a.shares)
        }, backup: { r in CloudArchive.rememberDeletes(of: r, paths: a); return true },
        removeFolder: { id, _ in await folder(id) })
    }

    func testEachStepOnceAndTheMeetingLeavesNoWord() async throws {
        let (a, _) = try world()
        var out = MoveOut(callID: id, to: work, started: t0)
        out.state = .removing
        let lib = library(a)
        try await MoveRemoval.advance(&out, paths: a, library: lib, ownerName: "Avery Webb",
                                      actions: actions(a, folder: { MoveRemoval.removeFolder($0, paths: a) }), now: t0)
        XCTAssertNil(out.nextStep)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.moves.appendingPathComponent("\(id).removing").path))
        XCTAssertTrue(ChatStore(directory: a.chats).all().isEmpty)
        let text = allText(a.root).lowercased()
        XCTAssertFalse(text.contains("zebra"), "a word of the meeting stayed")
        XCTAssertTrue(VoiceLibrary(directory: a.voices).profiles.first { $0.name == "Sam Carter" }?.embeddings.isEmpty ?? true)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.removed.count, 8)
    }

    /// Before each step, inside each step's write, and between each step and its save in the ledger, as the end of the
    /// process; then the next run goes on from the ledger. At every stop the meeting is whole in A or held by B (here
    /// B always holds it), and A's call folder is whole until the `folder` step.
    func testAStopBeforeOrAfterAnyStepGoesOnFromTheLedger() async throws {
        let counter = StopAt()
        do {
            let (a, _) = try world()
            var out = MoveOut(callID: id, to: work, started: t0)
            out.state = .removing
            try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb",
                                          actions: actions(a, folder: { MoveRemoval.removeFolder($0, paths: a, stop: counter.step) }), now: t0,
                                          stop: counter.step)
        }
        let total = counter.seen.count
        XCTAssertGreaterThanOrEqual(total, 18, "\(counter.seen)")
        for n in 0..<total {
            let (a, b) = try world()
            var out = MoveOut(callID: id, to: work, started: t0)
            out.state = .removing
            try out.save(a)
            let stop = StopAt(n)
            do {
                try await MoveRemoval.advance(&out, paths: a, library: library(a), ownerName: "Avery Webb",
                                              actions: actions(a, folder: { MoveRemoval.removeFolder($0, paths: a, stop: stop.step) }), now: t0,
                                              stop: stop.step)
                // A stop inside the folder step's own action ends that step as "not ended": no save, as the end of the
                // process would leave it.
                XCTAssertTrue(stop.seen.last?.hasPrefix("folder:") == true, "no stop at \(n)")
            } catch is MoveStop {}
            let saved = try XCTUnwrap(MoveOut.load(id, paths: a), "stop \(n)")
            let inA = FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent(CallRecord.fileName).path)
            let inB = FileManager.default.fileExists(atPath: b.callDirectory(id).appendingPathComponent(CallRecord.fileName).path)
            XCTAssertTrue(inA || inB, "stop \(n): in neither profile")
            if !saved.removed.contains(MoveOut.Step.folder.rawValue), stop.seen.last?.hasPrefix("folder") != true {
                XCTAssertTrue(inA, "stop \(n) (\(stop.seen.last ?? "")): A's folder went before its step")
            }
            // The next run.
            var next = saved
            try await MoveRemoval.advance(&next, paths: a, library: library(a), ownerName: "Avery Webb",
                                          actions: actions(a, folder: { MoveRemoval.removeFolder($0, paths: a) }), now: t0)
            XCTAssertNil(next.nextStep, "stop \(n)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path), "stop \(n)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.moves.appendingPathComponent("\(id).removing").path), "stop \(n)")
            XCTAssertFalse(allText(a.root).lowercased().contains("zebra"), "stop \(n): a word stayed")
            XCTAssertTrue(inB, "stop \(n): B still holds it")
        }
    }

    func testAPersonOnlyThatCallMadeIsDeletedAndOneWithAnotherMeetingStays() throws {
        let r = try writtenCall(in: temp())
        let made = Person(id: PersonID(rawValue: "p-new"), displayName: "Sam Carter", origin: .voiceNaming, at: r.start + 60)
        let older = Person(id: PersonID(rawValue: "p-old"), displayName: "Sam Carter", origin: .voiceNaming, at: r.start - 86_400)
        var owner = Person(id: PersonID(rawValue: "p-me"), displayName: "Avery Webb", origin: .owner, at: r.start + 60)
        owner.isOwner = true
        XCTAssertEqual(MoveRemoval.peopleToRemove(r, people: [made], samples: [], others: []).map(\.id.rawValue), ["p-new"])
        XCTAssertTrue(MoveRemoval.peopleToRemove(r, people: [older], samples: [], others: []).isEmpty, "made before the meeting")
        XCTAssertTrue(MoveRemoval.peopleToRemove(r, people: [owner], samples: [], others: []).isEmpty, "never the owner")
        var other = r
        other.id = "20261105-100000"
        XCTAssertTrue(MoveRemoval.peopleToRemove(r, people: [made], samples: [], others: [other]).isEmpty, "a voice of another meeting")
        let sample = VoiceSample(personID: made.id, vector: [1, 0], source: VoiceSampleSource(callID: "x", origin: .ownerNamed), learned: t0)
        XCTAssertTrue(MoveRemoval.peopleToRemove(r, people: [made], samples: [sample], others: []).isEmpty, "a sample left")
    }

    func testTheFolderIsRenamedOutOfAudioFirst() throws {
        let a = temp()
        try writtenCall(in: a)
        let stop = StopAt(2)
        XCTAssertThrowsError(try MoveRemoval.removeFolderOrStop(id, paths: a, stop: stop.step))
        XCTAssertEqual(stop.seen.last, "folder: delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).path), "out of Audio in one rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.moves.appendingPathComponent("\(id).removing/\(CallRecord.fileName)").path))
        XCTAssertTrue(MoveRemoval.removeFolder(id, paths: a), "the next run finishes it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.moves.appendingPathComponent("\(id).removing").path))
        XCTAssertTrue(MoveRemoval.removeFolder(id, paths: a), "gone counts as done")
    }
}
