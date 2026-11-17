import XCTest
@testable import MossadCore

/// Stops a step function at its Nth call, as the end of the process: no clean-up code runs after it.
final class StopAt: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int?
    private(set) var seen: [String] = []
    init(_ n: Int? = nil) { left = n }
    func step(_ name: String) throws {
        try lock.withLock {
            seen.append(name)
            guard let n = left else { return }
            if n == 0 { throw MoveStop() }
            left = n - 1
        }
    }
}

final class MoveCopyTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let token = "aaaa0001"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveCopyTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    /// Every file under a folder with its size and SHA-256.
    private func listing(_ dir: URL) -> [String: String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var out: [String: String] = [:]
        let base = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            out[path] = "\(MoveCopy.size(url) ?? -1) \((try? FileHash.sha256(of: url)) ?? "?")"
        }
        return out
    }

    private func world() throws -> (a: Paths, b: Paths, before: [String: String]) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try FileManager.default.createDirectory(at: b.root, withIntermediateDirectories: true)
        return (a, b, listing(a.root))
    }

    private func plan(_ a: Paths) throws -> MoveCopy.Plan {
        try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
    }

    func testACopyIsWholeAndChecked() throws {
        let (a, b, before) = try world()
        let p = try plan(a)
        let marker = try MoveCopy.write(p, from: "default", token: token, incoming: b.incoming, now: t0)
        try MoveCopy.publish(id, token: token, incoming: b.incoming)
        let folder = MoveMarker.folder(id, in: b)
        XCTAssertEqual(MoveMarker.look(folder), .incoming(marker))
        let chat = try XCTUnwrap(ChatStore(directory: a.chats).all().first)
        XCTAssertEqual(Set(marker.files.map(\.path)), ["call/call.json", "call/frames.json", "call/frames/000012000.heic", "call/me.caf",
                                                       "call/recording.m4a", "call/them.caf", "chats/\(chat.id.uuidString).json"])
        for f in marker.files {
            let url = folder.appendingPathComponent(f.path)
            XCTAssertEqual(MoveCopy.size(url), f.size, f.path)
            XCTAssertEqual(try FileHash.sha256(of: url), f.sha256, f.path)
        }
        XCTAssertEqual(try FileHash.sha256(of: folder.appendingPathComponent("call/recording.m4a")),
                       try FileHash.sha256(of: a.callDirectory(id).appendingPathComponent("recording.m4a")))
        XCTAssertEqual(marker.ownerKeys, ["me:A"])
        XCTAssertEqual(marker.token, token)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.root.path), ["Incoming"])
        for name in ["call.previous.json", "coach.json", "findings.json", "live.json", "live-points.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("call/\(name)").path), name)
        }
        XCTAssertEqual(try CallRecord.load(from: folder.appendingPathComponent("call")),
                       MovedRecord.prepared(try CallRecord.load(from: a.callDirectory(id)), to: work))
        XCTAssertEqual(listing(a.root), before, "A's folder is byte for byte as before")
    }

    /// Each sub-step of the copy and the publish, as the end of the process, then the next launch's step from the
    /// ledger. At every stop: A is byte for byte as before, and no `Incoming/<id>` exists until a whole, checked
    /// copy is published.
    func testEveryStopOfTheCopyAndThePublishGoesOnFromTheLedger() throws {
        let counter = StopAt()
        do {
            let (a, b, _) = try world()
            _ = try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0, stop: counter.step)
            try MoveCopy.publish(id, token: token, incoming: b.incoming, stop: counter.step)
        }
        let total = counter.seen.count
        XCTAssertGreaterThan(total, 10, "\(counter.seen)")
        for n in 0..<total {
            let (a, b, before) = try world()
            var out = MoveOut(callID: id, to: work, started: t0, token: token)
            let stop = StopAt(n)
            do {
                _ = try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0, stop: stop.step)
                out.state = .copied
                try MoveCopy.publish(id, token: token, incoming: b.incoming, stop: stop.step)
                XCTFail("no stop at \(n)")
            } catch is MoveStop {}
            XCTAssertEqual(listing(a.root), before, "stop \(n) (\(stop.seen.last ?? "")): A changed")
            let folder = MoveMarker.folder(id, in: b)
            let published = FileManager.default.fileExists(atPath: folder.path)
            if published { XCTAssertEqual(MoveMarker.look(folder).isIncoming(token: token), true, "stop \(n): a published folder is whole") }
            // The next launch.
            let part = MoveCopy.hasPart(id, token: token, incoming: b.incoming)
            switch MovePlan.source(out, marker: MoveMarker.look(folder), part: part, target: .live) {
            case .copy:
                _ = try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0)
                try MoveCopy.publish(id, token: token, incoming: b.incoming)
            case .publish:
                try MoveCopy.publish(id, token: token, incoming: b.incoming)
            case .markWaiting:
                XCTAssertTrue(published)
            case let other:
                XCTFail("stop \(n): \(other)")
            }
            guard case .incoming(let m) = MoveMarker.look(folder) else { return XCTFail("stop \(n): not published") }
            for f in m.files { XCTAssertEqual(try FileHash.sha256(of: folder.appendingPathComponent(f.path)), f.sha256, "stop \(n) \(f.path)") }
            XCTAssertFalse(MoveCopy.hasPart(id, token: token, incoming: b.incoming), "stop \(n): no part is left")
            XCTAssertEqual(listing(a.root), before, "stop \(n): A changed")
        }
    }

    func testAHalfCopyIsNeverPublished() throws {
        let (a, b, _) = try world()
        var calls = 0
        let failing: MoveCopy.FileCopy = { from, to, progress in
            calls += 1
            if calls == 3 { throw CocoaError(.fileWriteUnknown) }
            return try MoveCopy.file(from, to, progress)
        }
        XCTAssertThrowsError(try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0, copy: failing))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: b.incoming.path)) ?? [], [])
        let short: MoveCopy.FileCopy = { from, to, progress in
            let r = try MoveCopy.file(from, to, progress)
            let h = try FileHandle(forWritingTo: to)
            try h.truncate(atOffset: UInt64(max(0, r.size - 1)))
            try h.close()
            return r
        }
        XCTAssertThrowsError(try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0, copy: short)) {
            XCTAssertTrue($0 is MoveCopy.NotTheSame)
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: b.incoming.path)) ?? [], [])
        XCTAssertThrowsError(try MoveCopy.publish(id, token: token, incoming: b.incoming), "no part to publish")
    }

    func testAFullDiskLeavesNoPart() throws {
        let (a, b, _) = try world()
        let full: MoveCopy.FileCopy = { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0, copy: full)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteOutOfSpace)
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: b.incoming.path)) ?? [], [])
    }

    func testThePublishIsOneExclusiveRename() throws {
        let (a, b, _) = try world()
        _ = try MoveCopy.write(try plan(a), from: "default", token: token, incoming: b.incoming, now: t0)
        // An empty folder in the place: an exclusive rename never replaces it.
        try FileManager.default.createDirectory(at: MoveMarker.folder(id, in: b), withIntermediateDirectories: true)
        XCTAssertThrowsError(try MoveCopy.publish(id, token: token, incoming: b.incoming))
        XCTAssertTrue(MoveCopy.hasPart(id, token: token, incoming: b.incoming))
        try FileManager.default.removeItem(at: MoveMarker.folder(id, in: b))
        // Another volume refuses: nothing changes.
        XCTAssertThrowsError(try MoveCopy.publish(id, token: token, incoming: b.incoming, rename: { _, _ in EXDEV })) {
            XCTAssertTrue($0 is MoveCopy.OtherVolume)
        }
        XCTAssertTrue(MoveCopy.hasPart(id, token: token, incoming: b.incoming))
        try MoveCopy.publish(id, token: token, incoming: b.incoming)
        XCTAssertFalse(MoveCopy.hasPart(id, token: token, incoming: b.incoming))
    }

    func testAPlanRefusesAFolderInWorkOrWithAFileItDoesNotKnow() throws {
        let (a, _, _) = try world()
        try Data().write(to: a.callDirectory(id).appendingPathComponent("notes.txt"))
        XCTAssertThrowsError(try plan(a)) { XCTAssertEqual($0 as? MoveCopy.Refused, .unknownFile) }
        try FileManager.default.removeItem(at: a.callDirectory(id).appendingPathComponent("notes.txt"))
        try Data().write(to: a.callDirectory(id).appendingPathComponent("merge.json"))
        XCTAssertThrowsError(try plan(a)) { XCTAssertEqual($0 as? MoveCopy.Refused, .inWork) }
    }

    func testAChatThatReadOtherMeetingsDoesNotGo() throws {
        let (a, _, _) = try world()
        var wide = Chat(title: "Zebra budget")
        wide.callID = id
        wide.messages = [ChatMessage(role: .assistant, text: "An answer", steps: ["Searching transcripts for “budget”"])]
        try ChatStore(directory: a.chats).save(wide)
        let p = try plan(a)
        XCTAssertFalse(p.chats.contains { $0.id == wide.id })
        XCTAssertEqual(p.deletedChats, [wide.id])
    }

    func testARecordingOnlyInTheBackupIsFetchedAndChecked() async throws {
        let a = temp()
        try writtenCall(in: a)
        let dir = a.callDirectory(id)
        for name in ["me.caf", "them.caf", "recording.m4a"] { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        let audio = Data(repeating: 5, count: 2048)
        let source = a.root.appendingPathComponent("made-up-download.m4a")
        try audio.write(to: source)
        var r = try CallRecord.load(from: dir)
        r.cloudKey = "recordings/\(id)/recording.m4a"
        r.cloudSize = 2048
        r.cloudBackend = "server"
        r.cloudServer = "srv-1"
        r.cloudHash = try FileHash.sha256(of: source)
        try r.save(to: dir)
        XCTAssertTrue(MoveCopy.needsFetch(r, in: dir))
        let archive = CloudArchive(target: .server, places: [FakeArchive(.server, id: "srv-1")], paths: a)
        let folder = a.moves.appendingPathComponent("\(id).download")
        let got = await archive.fetch(r, into: folder, download: { _, _ in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        })
        let file = try XCTUnwrap(got)
        XCTAssertEqual(MoveCopy.size(file), 2048)
        let p = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: file)
        XCTAssertTrue(p.files.contains { $0.path == "call/recording.m4a" && $0.from == file })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.m4a").path), "A's folder does not change")
        // Another size, no answer, and no place set up: nil.
        try Data(repeating: 5, count: 100).write(to: source)
        let wrong = await archive.fetch(r, into: folder, download: { _, _ in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        })
        XCTAssertNil(wrong)
        let v1 = await archive.fetch(r, into: folder, download: { _, _ in throw URLError(.timedOut) })
        XCTAssertNil(v1)
        let v2 = await CloudArchive(target: nil, places: [], paths: a).fetch(r, into: folder, download: { _, _ in source })
        XCTAssertNil(v2)
        r.speakerEmbeddings = [:]
        try Data().write(to: dir.appendingPathComponent("me.caf"))
        XCTAssertFalse(MoveCopy.needsFetch(r, in: dir))
    }

    func testAMarkedCallIsNeverProcessedHere() async throws {
        let a = temp()
        try a.ensureDirectories()
        var rec = CallRecord(id: "20261103-100000", platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 600, status: .recorded)
        rec.moveTo = work
        let dir = a.callDirectory(rec.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rec.save(to: dir)
        XCTAssertFalse(ProcessingQueue(paths: a).pending(now: t0 + 9999).contains { $0.id == rec.id })
        let transcriber = FakeTranscriber(), summarizer = FakeSummarizer()
        let pipeline = Pipeline(paths: a, transcriber: transcriber, library: VoiceLibrary(directory: a.voices), embeddings: ToneEmbeddingProvider(),
                                calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        await pipeline.process(rec.id)
        await pipeline.retry(rec.id)
        await pipeline.runPending()
        XCTAssertEqual(try CallRecord.load(from: dir).status, .recorded)
        XCTAssertEqual(transcriber.calls.count, 0)

        try writtenCall(in: a)
        let written = a.callDirectory(id)
        let v3 = await pipeline.setMoveTarget(callID: id, work)
        XCTAssertTrue(v3)
        let before = listing(written)
        await pipeline.regenerateSummary(id)
        _ = await pipeline.transcribeAgain(id, speakers: nil)
        await pipeline.applyNames(callID: id, names: ["them:B": "Mira Stone"])
        let v4 = await pipeline.merge(callIDs: [id, rec.id])
        XCTAssertNil(v4)
        let v5 = await pipeline.delete(callID: id)
        XCTAssertFalse(v5)
        let v6 = await pipeline.attachNotes(callID: id, GeminiNotesRef(docID: "d", title: "t", url: nil, eventID: nil, imported: t0, notes: nil))
        XCTAssertFalse(v6)
        let v7 = await pipeline.restorePreviousTranscript(id)
        XCTAssertFalse(v7)
        XCTAssertEqual(listing(written), before, "nothing changed on disk")
        XCTAssertEqual(summarizer.calls, 0)
    }

    func testAMarkIsRefusedForACallInWork() async throws {
        let a = temp()
        try writtenCall(in: a)
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: VoiceLibrary(directory: a.voices), embeddings: ToneEmbeddingProvider(),
                                calendar: FakeCalendar(), summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let v8 = await pipeline.isBusy(id)
        XCTAssertFalse(v8)
        let v9 = await pipeline.setMoveTarget(callID: id, work)
        XCTAssertTrue(v9)
        XCTAssertEqual(try CallRecord.load(from: a.callDirectory(id)).moveTo, work)
        let v10 = await pipeline.setMoveTarget(callID: id, "5e6f7a8b")
        XCTAssertFalse(v10, "marked for another profile")
        let v11 = await pipeline.setMoveTarget(callID: id, nil)
        XCTAssertTrue(v11)
        XCTAssertNil(try CallRecord.load(from: a.callDirectory(id)).moveTo)
        var live = CallRecord(id: "20261104-100000", platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0, status: .recording)
        let dir = a.callDirectory(live.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try live.save(to: dir)
        let v12 = await pipeline.setMoveTarget(callID: live.id, work)
        XCTAssertFalse(v12, "the call that records now")
        live.status = .recorded
        let v13 = await pipeline.setMoveTarget(callID: "20200101-000000", work)
        XCTAssertFalse(v13, "a record that cannot be read")
    }
}

extension MoveMarker.Look {
    func isIncoming(token: String) -> Bool {
        if case .incoming(let m) = self { return m.token == token }
        return false
    }
}
