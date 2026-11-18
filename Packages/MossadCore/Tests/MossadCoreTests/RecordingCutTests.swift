import XCTest
@testable import MossadCore

/// The cut step: a recording becomes two recordings with no sample lost, and a stop at any point leaves either the
/// original whole or every part whole.
final class RecordingCutTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)
    /// The original's id from its start, as the recorder gives it, so the first part cannot take it.
    private var id: String { CallRecorder.callID(for: t0) }
    private var second: String { CallRecorder.callID(for: t0 + cutAt) }
    private let length: TimeInterval = 150
    private let cutAt: TimeInterval = 90

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingCutTests-\(UUID().uuidString)")
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

    private func pipeline(_ a: Paths, library lib: VoiceLibrary? = nil) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib ?? library(a), embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                 summarizer: nil, notify: { _ in }, now: { [t0] in t0 + 7200 }, ownerName: "Avery Webb")
    }

    /// A recorded call of 150 s with both tracks, a bookmark in each half, and a frame in each half.
    @discardableResult
    private func recorded(_ a: Paths, status: CallStatus = .recorded) throws -> CallRecord {
        let dir = a.callDirectory(id)
        try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        try AudioCutTests.writeTrack(dir.appendingPathComponent("me.caf"), frames: Int(length * 16_000))
        try AudioCutTests.writeTrack(dir.appendingPathComponent("them.caf"), frames: Int(length * 16_000) - 77)
        var index = FrameIndex()
        for o in [30.0, 100.0] {
            let f = FrameIndex.Frame(offset: o, file: FrameIndex.fileName(offset: o), text: "slide \(Int(o))")
            try Data("pic".utf8).write(to: index.url(of: f, in: dir))
            index.insert(f)
        }
        try index.save(to: dir)
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + length, status: status)
        r.meetingID = "aaa-bbbb-ccc"
        r.markers = [TranscriptMarker(offset: 20, text: "★", isBookmark: true), TranscriptMarker(offset: 120, text: "★", isBookmark: true)]
        r.callMarks = [CallMark(at: cutAt, time: t0 + cutAt, link: "ddd-eeee-fff", platform: .meet, source: .tabs, sure: true)]
        try r.save(to: dir)
        return r
    }

    private func samples(_ url: URL) throws -> [Int16] { try AudioCutTests.samples(url) }

    private func audioNames(_ a: Paths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: a.audio.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testACutOfARecordedCallGivesTwoRecordedPartsWhoseTracksAddUp() async throws {
        let a = temp()
        try recorded(a)
        let before = try ["me.caf", "them.caf"].map { try samples(a.callDirectory(id).appendingPathComponent($0)) }
        let ids = try await pipeline(a).cut(callID: id, at: [Cut(at: cutAt, link: "ddd-eeee-fff")])
        XCTAssertEqual(ids, ["\(id)-2", second])
        XCTAssertEqual(audioNames(a), ids, "no original, no part in the making")
        for (n, name) in ["me.caf", "them.caf"].enumerated() {
            let joined = try ids.flatMap { try samples(a.callDirectory($0).appendingPathComponent(name)) }
            XCTAssertEqual(joined, before[n], name)
        }
        let parts = try ids.map { try CallRecord.load(from: a.callDirectory($0)) }
        XCTAssertEqual(parts.map(\.status), [.recorded, .recorded])
        XCTAssertEqual(parts.map(\.cutFrom), [id, id])
        XCTAssertEqual(parts.map(\.meetingID), ["aaa-bbbb-ccc", "ddd-eeee-fff"])
        XCTAssertEqual(parts.map { $0.markers.map(\.offset) }, [[20], [30]])
        XCTAssertEqual(FrameIndex.load(from: a.callDirectory(ids[1]))?.frames.map(\.file), ["10000.heic"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.callDirectory(ids[1]).appendingPathComponent("frames/10000.heic").path))
        for id in ids { XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent("cut.json").path)) }
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999).map(\.id), ids, "each part is processed as its own call")
    }

    func testARefusedCutChangesNothing() async throws {
        let a = temp()
        try recorded(a)
        let before = try FileManager.default.contentsOfDirectory(atPath: a.callDirectory(id).path).sorted()
        let p = pipeline(a)
        for cuts in [[Cut(at: 30, link: nil)], [Cut(at: 200, link: nil)], []] {
            do {
                _ = try await p.cut(callID: id, at: cuts)
                XCTFail("refused: \(cuts)")
            } catch let error as Pipeline.CutError {
                guard case .refused = error else { return XCTFail("refused, not failed: \(error)") }
            }
        }
        XCTAssertEqual(audioNames(a), [id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.callDirectory(id).path).sorted(), before)
    }

    func testACutWithNoRawTracksIsRefused() async throws {
        let a = temp()
        try recorded(a)
        for name in ["me.caf", "them.caf"] { try FileManager.default.removeItem(at: a.callDirectory(id).appendingPathComponent(name)) }
        do {
            _ = try await pipeline(a).cut(callID: id, at: [Cut(at: cutAt, link: nil)])
            XCTFail("refused")
        } catch {}
        XCTAssertEqual(audioNames(a), [id])
    }

    /// Review focus 1: a stop at each point of each phase, then the next run. Before `published` the original is
    /// whole and no part exists; from it, both parts are whole and the original is gone. Never neither.
    func testAStopAtEachPointThenTheNextRun() async throws {
        let points = ["copying saved", "copying done", "checked saved", "checked done", "published saved", "published \(id)-2",
                      "published done", "forgetting saved", "forgetting done", "removed saved", "folder: out of Audio",
                      "folder: the note", "folder: delete", "removed done"]
        for point in points {
            let a = temp()
            try recorded(a)
            let before = try ["me.caf", "them.caf"].map { try samples(a.callDirectory(id).appendingPathComponent($0)) }
            let p = pipeline(a)
            await p.setCutStop { if $0 == point { throw Boom() } }
            do {
                _ = try await p.cut(callID: id, at: [Cut(at: cutAt, link: nil)])
                XCTFail("stopped at \(point)")
            } catch {}
            try assertWholeSomewhere(a, before: before, point)
            XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999), [], "nothing is processed while a cut is in progress: \(point)")

            let next = pipeline(a)
            await next.finishInterruptedCuts()
            // From `checked` the next run checks the parts again and goes forward when they are whole.
            let forward = !["copying saved", "copying done"].contains(point)
            if forward {
                let ids = ["\(id)-2", second]
                XCTAssertEqual(audioNames(a), ids, point)
                for (n, name) in ["me.caf", "them.caf"].enumerated() {
                    XCTAssertEqual(try ids.flatMap { try samples(a.callDirectory($0).appendingPathComponent(name)) }, before[n], "\(point) \(name)")
                }
                for id in ids { XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent("cut.json").path), point) }
            } else {
                XCTAssertEqual(audioNames(a), [id], point)
                for (n, name) in ["me.caf", "them.caf"].enumerated() {
                    XCTAssertEqual(try samples(a.callDirectory(id).appendingPathComponent(name)), before[n], "\(point) \(name)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: a.callDirectory(id).appendingPathComponent("cut.json").path), point)
                XCTAssertEqual(try CallRecord.load(from: a.callDirectory(id)).status, .recorded)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: CallForget.deleting(a).appendingPathComponent("\(id).removing").path)
                           && forward == false, point)
        }
    }

    /// After a stop: the original whole (its two tracks as they were), or every part whole.
    private func assertWholeSomewhere(_ a: Paths, before: [[Int16]], _ point: String) throws {
        let originalWhole = (try? ["me.caf", "them.caf"].map { try samples(a.callDirectory(id).appendingPathComponent($0)) }) == before
        let ids = ["\(id)-2", second]
        let partsWhole = (try? ["me.caf", "them.caf"].map { name in
            try ids.flatMap { try samples(a.callDirectory($0).appendingPathComponent(name)) }
        }) == before
        XCTAssertTrue(originalWhole || partsWhole, "neither the original nor the parts are whole at \(point)")
    }

    /// A written original (the repair): its tasks, the chats about it, its voice samples, and its note go; a tick
    /// made after the cut belongs to the second part, and the live chat goes to the part it was asked in.
    func testAWrittenOriginalIsForgottenAndTheOwnersTicksGoToTheirPart() async throws {
        let a = temp()
        var r = try recorded(a, status: .written)
        let note = a.meetings.appendingPathComponent("2026-11-01 1000 - Zebra.md")
        try Data("# Zebra\n".utf8).write(to: note)
        r.markdownPath = note.path
        r.speakerNames = ["them:A": "Sam Carter"]
        r.speakerEmbeddings = ["them:A": (0..<8).map { Float($0) / 8 }]
        try r.save(to: a.callDirectory(id))
        let lib = library(a)
        try lib.add(r.speakerEmbeddings["them:A"]!, to: "Sam Carter",
                    source: VoiceSampleSource(callID: id, speakerKey: "them:A", recorded: t0, seconds: 30, quality: 0.8, origin: .ownerNamed))
        var tasks = CommitmentBook()
        tasks.items = [Commitment(text: "Send the zebra budget", to: "Sam Carter", callID: id, callTitle: "Zebra", madeAt: t0, due: nil, created: t0)]
        try tasks.save(to: a.commitments)
        var book = NextTimeBook()
        var early = NextTimePoint(text: "Ask about the zebra", rank: 1, created: t0 - 100)
        early.done = .init(callID: id, at: 40, quote: nil, date: t0 + 40, byOwner: true)
        var late = NextTimePoint(text: "Ask about the crossing", rank: 2, created: t0 - 100)
        late.done = .init(callID: id, at: 100, quote: nil, date: t0 + 100, byOwner: true)
        var found = NextTimePoint(text: "Budget", rank: 3, created: t0 - 100)
        found.done = .init(callID: id, at: 110, quote: "the budget", date: t0 + 200, byOwner: false)
        book.points = [early, late, found]
        try book.save(to: a.nextTime)
        let chats = ChatStore(directory: a.chats)
        var after = Chat(title: "What did we decide?")
        after.callID = id
        after.messages = [ChatMessage(role: .user, text: "What did we decide?")]
        try chats.save(after)
        var live = Chat(title: "Who is talking?")
        live.callID = id
        var q = ChatMessage(role: .user, text: "Who is talking?")
        q.asked = t0 + 120
        var answer = ChatMessage(role: .assistant, text: "Sam Carter")
        answer.live = true
        live.messages = [q, answer]
        try chats.save(live)

        let ids = try await pipeline(a, library: lib).cut(callID: id, at: [Cut(at: cutAt, link: nil)])
        XCTAssertEqual(audioNames(a), ids)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path), "the old note goes")
        XCTAssertTrue(try CommitmentBook.load(from: a.commitments).items.allSatisfy { $0.deleted }, "its tasks go")
        XCTAssertFalse(lib.identity!.samples.samples.contains { $0.callID == id }, "its voice samples go")
        XCTAssertTrue(lib.identity!.people.people.contains { $0.isLive && $0.displayName == "Sam Carter" }, "the person stays")
        let points = try NextTimeBook.load(from: a.nextTime).points
        XCTAssertEqual(points[0].done?.callID, ids[0])
        XCTAssertEqual(points[0].done?.at, 40)
        XCTAssertEqual(points[1].done?.callID, ids[1], "a tick made after the cut belongs to the second part")
        XCTAssertEqual(points[1].done?.at, 10)
        XCTAssertNil(points[2].done, "what the check found is checked again on each part")
        let left = ChatStore(directory: a.chats).all()
        XCTAssertEqual(left.map(\.id), [live.id], "the chat about the written meeting goes; the live chat stays")
        XCTAssertEqual(left.first?.callID, ids[1], "the live chat goes to the part it was asked in")
    }

    func testTwoPartsOfOneCutAreNeverJoinedAgain() async throws {
        let a = temp()
        try recorded(a)
        // One link on both sides of the cut: a reload, or a cut by hand at the same link.
        let ids = try await pipeline(a).cut(callID: id, at: [Cut(at: cutAt, link: "aaa-bbbb-ccc")])
        let parts = try ids.map { try CallRecord.load(from: a.callDirectory($0)) }
        XCTAssertEqual(parts[0].meetingID, parts[1].meetingID)
        XCTAssertFalse(MeetingMerge.continues(.init(parts[0]), .init(parts[1])))
    }
}
