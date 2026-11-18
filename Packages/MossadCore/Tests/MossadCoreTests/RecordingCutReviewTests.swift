import AVFoundation
import XCTest
@testable import MossadCore

/// The review's rules for the cut: the check compares samples, no state lasts for ever, and each refusal holds.
final class RecordingCutReviewTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)
    private let cutAt: TimeInterval = 90
    private var id: String { CallIDs.callID(for: t0) }
    private var first: String { "\(id)-2" }
    private var second: String { CallIDs.callID(for: t0 + cutAt) }

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingCutReviewTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let p = Paths(root: url)
        try! p.ensureDirectories()
        return p
    }

    private func library(_ a: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: a.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        return l
    }

    private func pipeline(_ a: Paths, library lib: VoiceLibrary? = nil, gate: HeavyWorkGate = HeavyWorkGate()) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib ?? library(a), embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: nil, notify: { _ in }, now: { [t0] in t0 + 7200 }, ownerName: "Avery Webb", heavy: gate)
    }

    @discardableResult
    private func recorded(_ a: Paths, status: CallStatus = .recorded) throws -> CallRecord {
        let dir = a.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AudioCutTests.writeTrack(dir.appendingPathComponent("me.caf"), frames: 150 * 16_000)
        try AudioCutTests.writeTrack(dir.appendingPathComponent("them.caf"), frames: 150 * 16_000 - 33)
        let r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 150, status: status)
        try r.save(to: dir)
        return r
    }

    /// A written original, as the real run has it: a note, a task, a chat, a voice sample, and a backup copy.
    private func written(_ a: Paths, _ lib: VoiceLibrary) throws -> CallRecord {
        try recorded(a, status: .written)
        var r = try CallRecord.load(from: a.callDirectory(id))
        let note = a.meetings.appendingPathComponent("2026-11-01 0800 - Zebra.md")
        try Data("# Zebra\n".utf8).write(to: note)
        r.markdownPath = note.path
        r.speakerNames = ["them:A": "Sam Carter"]
        r.speakerEmbeddings = ["them:A": (0..<8).map { Float($0) / 8 }]
        r.cloudKey = "recordings/\(id)/recording.m4a"
        r.cloudSize = 2048
        try r.save(to: a.callDirectory(id))
        try lib.add(r.speakerEmbeddings["them:A"]!, to: "Sam Carter",
                    source: VoiceSampleSource(callID: id, speakerKey: "them:A", recorded: t0, seconds: 30, quality: 0.8, origin: .ownerNamed))
        var tasks = CommitmentBook()
        tasks.items = [Commitment(text: "Send the zebra budget", to: "Sam Carter", callID: id, callTitle: "Zebra", madeAt: t0, due: nil, created: t0)]
        try tasks.save(to: a.commitments)
        var chat = Chat(title: "What did we decide?")
        chat.callID = id
        chat.messages = [ChatMessage(role: .user, text: "What did we decide?")]
        try ChatStore(directory: a.chats).save(chat)
        return r
    }

    private func names(_ a: Paths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: a.audio.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func ledger(_ a: Paths, phase: Pipeline.CutLedger.Phase, ids: [String]? = nil) throws {
        let parts = [CallForget.CutPart(id: first, from: 0, start: t0, end: t0 + cutAt), CallForget.CutPart(id: second, from: cutAt, start: t0 + cutAt, end: t0 + 150)]
        try Pipeline.CutLedger(original: id, ids: ids ?? [first, second], cuts: [Cut(at: cutAt, link: nil)], phase: phase, parts: parts)
            .save(in: a.callDirectory(id))
    }

    /// The parts as the copy makes them, in their `.cutting` folders.
    private func copied(_ a: Paths) async throws {
        let p = pipeline(a)
        let plan = await p.cutPlan(callID: id, at: [Cut(at: cutAt, link: nil)])
        try Pipeline.copyParts(of: a.callDirectory(id), parts: plan.parts, cuts: [Cut(at: cutAt, link: nil)], paths: a)
    }

    private func cutting(_ a: Paths, _ part: String) -> URL { a.audio.appendingPathComponent(part + Pipeline.cuttingSuffix) }

    // MARK: I7 and I8: the check

    func testTheCheckPassesForAWholeCopy() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        XCTAssertNoThrow(try Pipeline.checkParts(of: a.callDirectory(id), ids: [first, second], cuts: [Cut(at: cutAt, link: nil)], paths: a))
    }

    func testTheCheckFailsForAPartCutShort() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        try trimAudioFile(cutting(a, second).appendingPathComponent("them.caf"), to: 30)
        XCTAssertThrowsError(try Pipeline.checkParts(of: a.callDirectory(id), ids: [first, second], cuts: [Cut(at: cutAt, link: nil)], paths: a))
    }

    func testTheCheckFailsForOneChangedSample() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        // The same count, one sample changed: a count alone would pass.
        let url = cutting(a, first).appendingPathComponent("me.caf")
        try rewriteAudioFile(url, keep: nil, silence: [10.0...10.0001])
        XCTAssertEqual(try AudioCut.frames(url), Int64(cutAt * 16_000))
        XCTAssertThrowsError(try Pipeline.checkParts(of: a.callDirectory(id), ids: [first, second], cuts: [Cut(at: cutAt, link: nil)], paths: a))
    }

    /// A resume at `checked` checks again before it publishes: a bad part rolls back, a good one goes forward.
    func testAResumeAtCheckedChecksAgain() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        try ledger(a, phase: .checked)
        try rewriteAudioFile(cutting(a, second).appendingPathComponent("them.caf"), keep: nil, silence: [5.0...5.0001])
        await pipeline(a).finishInterruptedCuts()
        XCTAssertEqual(names(a), [id], "a part that does not match: rolled back")
        XCTAssertNil(Pipeline.CutLedger.load(in: a.callDirectory(id)))

        try await copied(a)
        try ledger(a, phase: .checked)
        await pipeline(a).finishInterruptedCuts()
        XCTAssertEqual(names(a), [first, second], "whole parts: published")
    }

    /// I8: a real error (not a test's stop) rolls the cut back in the same run.
    func testARealErrorRollsBack() async throws {
        let a = temp()
        try recorded(a)
        try Data("not audio".utf8).write(to: a.callDirectory(id).appendingPathComponent("them.caf"))
        do {
            _ = try await pipeline(a).cut(callID: id, at: [Cut(at: cutAt, link: nil)])
            XCTFail("the check fails on a track that does not open")
        } catch let error as Pipeline.CutError {
            guard case .failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(names(a), [id])
        XCTAssertNil(Pipeline.CutLedger.load(in: a.callDirectory(id)))
    }

    // MARK: I6: no state that never ends

    func testAPartMissingInBothFormsRollsBack() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        try FileManager.default.removeItem(at: cutting(a, second))
        try ledger(a, phase: .published)
        await pipeline(a).finishInterruptedCuts()
        XCTAssertEqual(names(a), [id], "the original, whole, as one meeting; the part in place goes")
        XCTAssertNil(Pipeline.CutLedger.load(in: a.callDirectory(id)))
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999).map(\.id), [id])
    }

    func testARenameThatFailsThreeTimesRollsBack() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        // A folder of something else at the part's id: the rename fails, and it is never taken for the part.
        let other = a.callDirectory(second)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("keep.txt"))
        try ledger(a, phase: .published)
        for run in 1...2 {
            await pipeline(a).finishInterruptedCuts()
            XCTAssertEqual(Pipeline.CutLedger.load(in: a.callDirectory(id))?.renameTries, run, "run \(run)")
        }
        await pipeline(a).finishInterruptedCuts()
        XCTAssertNil(Pipeline.CutLedger.load(in: a.callDirectory(id)), "the third failure rolls back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("keep.txt").path), "the other folder is not touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutting(a, second).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent("me.caf").path))
    }

    func testALedgerThatDoesNotReadIsSetAsideAndTheOriginalIsProcessed() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        try Data("{ not a ledger".utf8).write(to: a.callDirectory(id).appendingPathComponent(Pipeline.CutLedger.fileName))
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999), [])
        await pipeline(a).finishInterruptedCuts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent(Pipeline.CutLedger.fileName).path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: a.callDirectory(id).path).filter { $0.hasPrefix("cut.unreadable") }
        XCTAssertEqual(kept.count, 1, "set aside under another name")
        XCTAssertEqual(names(a), [id], "the parts in the making are swept")
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999).map(\.id), [id])
    }

    // MARK: I8: the sweep, the lists, the refusals, the heavy step

    func testAnOrphanPartInTheMakingIsSweptAndNeverListed() async throws {
        let a = temp()
        try recorded(a)
        try await copied(a)
        XCTAssertEqual(ProcessingQueue(paths: a).allRecords().map(\.id), [id], "no list reads a part in the making")
        await pipeline(a).finishInterruptedCuts()
        XCTAssertEqual(names(a), [id])
    }

    func testEachRefusalThatNeedsTheDisk() async throws {
        let cut = [Cut(at: cutAt, link: nil)]
        func refused(_ a: Paths, _ why: String, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                _ = try await pipeline(a).cut(callID: id, at: cut)
                XCTFail("refused: \(why)", file: file, line: line)
            } catch {}
            XCTAssertTrue(names(a).allSatisfy { !$0.hasSuffix(Pipeline.cuttingSuffix) }, why, file: file, line: line)
        }
        var a = temp()
        try recorded(a)
        try Data("{}".utf8).write(to: a.callDirectory(id).appendingPathComponent(Pipeline.MergePlan.fileName))
        await refused(a, "a merge in progress")

        a = temp()
        try recorded(a)
        try ledger(a, phase: .forgetting)
        await refused(a, "a cut in progress")

        a = temp()
        try recorded(a)
        var deletes = DeleteLedger()
        deletes.entries = [.init(callID: id, removed: [], started: t0)]
        try deletes.save(a)
        await refused(a, "a Delete in progress")

        a = temp()
        try recorded(a)
        try Data("{ not json".utf8).write(to: a.root.appendingPathComponent(DeleteLedger.fileName))
        await refused(a, "a list of deletes that does not read")

        a = temp()
        var marked = try recorded(a, status: .written)
        marked.moveTo = "1a2b3c4d"
        try marked.save(to: a.callDirectory(id))
        await refused(a, "marked for another profile")
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var on: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// The copy goes through `HeavyStep.recordingCut`: it waits while a call records, and the call is in work meanwhile.
    func testTheCopyWaitsWhileACallRecords() async throws {
        let a = temp()
        try recorded(a)
        let call = Flag()
        let gate = HeavyWorkGate(pollInterval: .milliseconds(20)) { call.on }
        let p = pipeline(a, gate: gate)
        let callID = id, cut = [Cut(at: cutAt, link: nil)]
        let run = Task { try await p.cut(callID: callID, at: cut) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(names(a), [id], "nothing is copied while a call records")
        XCTAssertNil(Pipeline.CutLedger.load(in: a.callDirectory(id)))
        do {
            _ = try await p.cut(callID: id, at: [Cut(at: cutAt, link: nil)])
            XCTFail("in work")
        } catch {}
        call.on = false
        let ids = try await run.value
        XCTAssertEqual(ids, [first, second])
        XCTAssertEqual(HeavyStep.recordingCut.runsDuringCall, false)
    }

    // MARK: I8: a stop at each phase with a written original

    func testAStopAtEachPhaseOfAWrittenOriginal() async throws {
        let points = ["copying saved", "copying done", "checked saved", "checked done", "published saved", "published done",
                      "forgetting saved", "forgetting done", "removed saved", "folder: out of Audio", "removed done"]
        for point in points {
            let a = temp()
            let lib = library(a)
            let r = try written(a, lib)
            let before = try ["me.caf", "them.caf"].map { try AudioCutTests.samples(a.callDirectory(id).appendingPathComponent($0)) }
            let p = pipeline(a, library: lib)
            await p.setCutStop { if $0 == point { throw Boom() } }
            do {
                _ = try await p.cut(callID: id, at: [Cut(at: cutAt, link: nil)])
                XCTFail("stopped at \(point)")
            } catch {}
            await pipeline(a, library: lib).finishInterruptedCuts()
            // From `checked` the next run checks again and goes forward when the parts are whole.
            let forward = !["copying saved", "copying done"].contains(point)
            if forward {
                XCTAssertEqual(names(a), [first, second], point)
                for (n, name) in ["me.caf", "them.caf"].enumerated() {
                    XCTAssertEqual(try [first, second].flatMap { try AudioCutTests.samples(a.callDirectory($0).appendingPathComponent(name)) }, before[n], "\(point) \(name)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: r.markdownPath!), "the old note: \(point)")
                XCTAssertTrue(try CommitmentBook.load(from: a.commitments).items.allSatisfy(\.deleted), "the tasks: \(point)")
                XCTAssertTrue(ChatStore(directory: a.chats).all().isEmpty, "the chat: \(point)")
                XCTAssertFalse(lib.identity!.samples.samples.contains { $0.callID == id }, "the samples: \(point)")
                XCTAssertTrue(CloudArchive.pendingDeletes(in: a.sync.appendingPathComponent("backup-deletes.json")).contains { $0.key == r.cloudKey }, "the backup: \(point)")
                XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: CallForget.deleting(a).path)) ?? []).isEmpty, point)
            } else {
                XCTAssertEqual(names(a), [id], point)
                for (n, name) in ["me.caf", "them.caf"].enumerated() {
                    XCTAssertEqual(try AudioCutTests.samples(a.callDirectory(id).appendingPathComponent(name)), before[n], "\(point) \(name)")
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: r.markdownPath!), point)
                XCTAssertFalse(try CommitmentBook.load(from: a.commitments).items.contains(where: \.deleted), point)
                XCTAssertEqual(ChatStore(directory: a.chats).all().count, 1, point)
                XCTAssertTrue(lib.identity!.samples.samples.contains { $0.callID == id }, point)
                XCTAssertEqual(try CallRecord.load(from: a.callDirectory(id)).status, .written)
            }
        }
    }
}
