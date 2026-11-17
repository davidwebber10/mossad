import XCTest
@testable import MossadCore

final class MoveIntakeTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let token = "token-a"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveIntakeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func listing(_ dir: URL) -> [String: String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var out: [String: String] = [:]
        let base = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = (try? FileHash.sha256(of: url)) ?? "?"
        }
        return out
    }

    /// A and B, the meeting published in `B/Incoming`.
    private func arrive(fill: (Paths) throws -> Void = { _ in }) throws -> (a: Paths, b: Paths, marker: MoveMarker) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        try fill(b)
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        let marker = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0)
        try MoveCopy.publish(id, token: token, incoming: b.incoming)
        return (a, b, marker)
    }

    private func intake(_ b: Paths, stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveIntake {
        let library = VoiceLibrary(directory: b.voices)
        library.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices))
        return MoveIntake(paths: b, me: work, library: library, ownerName: { "Avery Webb" }, voiceFingerprints: { true }, stop: stop)
    }

    private func claimed(_ b: Paths, _ callID: String? = nil) -> MoveMarker? {
        if case .claimed(let m) = MoveMarker.look(MoveMarker.folder(callID ?? id, in: b)) { return m }
        return nil
    }

    func testATakenMeetingIsWholeInAudio() throws {
        let (a, b, _) = try arrive()
        XCTAssertEqual(intake(b).run(), [id])
        let dir = b.callDirectory(id)
        XCTAssertEqual(Set(listing(dir).keys), ["call.json", "me.caf", "them.caf", "recording.m4a", "frames.json", "frames/000012000.heic"])
        for name in ["me.caf", "them.caf", "recording.m4a", "frames/000012000.heic"] {
            XCTAssertEqual(listing(dir)[name], listing(a.callDirectory(id))[name], name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: MoveMarker.folder(id, in: b).path), [MoveMarker.claimedName])
        let m = try XCTUnwrap(claimed(b))
        XCTAssertEqual(m.intake, .taken)
        XCTAssertEqual(m.finalID, id)
        XCTAssertEqual(m.token, token, "A's token stays")
        XCTAssertEqual(m.count, m.files.count, "every file was checked")
        XCTAssertTrue(m.heldWhole)
        let r = try CallRecord.load(from: dir)
        XCTAssertEqual(r.id, id)
        XCTAssertEqual(r.status, .summarized)
        XCTAssertNil(r.markdownPath)
        XCTAssertNil(r.speakerPeople)
        XCTAssertNil(r.moveTo)
        let chats = ChatStore(directory: b.chats).all()
        let original = try XCTUnwrap(ChatStore(directory: a.chats).all().first)
        XCTAssertEqual(chats.count, 1)
        XCTAssertNotEqual(chats.first?.id, original.id)
        XCTAssertEqual(chats.first?.callID, id)
        XCTAssertTrue(chats.first?.messages.allSatisfy { $0.actions == nil } ?? false)
        XCTAssertEqual(chats.first?.messages.map(\.text), original.messages.map(\.text))
        XCTAssertFalse(MoveIntake.hasWork(b))
    }

    func testTheIDThatIsTakenGetsMoved() throws {
        let other = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 60, status: .written)
        let (_, b, _) = try arrive { b in
            try FileManager.default.createDirectory(at: b.callDirectory(other.id), withIntermediateDirectories: true)
            try other.save(to: b.callDirectory(other.id))
        }
        let theirs = listing(b.callDirectory(id))
        XCTAssertEqual(intake(b).run(), [id + "-moved"])
        XCTAssertEqual(try CallRecord.load(from: b.callDirectory(id + "-moved")).id, id + "-moved")
        let chat = try XCTUnwrap(ChatStore(directory: b.chats).all().first)
        XCTAssertEqual(chat.callID, id + "-moved")
        XCTAssertTrue(chat.messages.contains { $0.text.contains("mossad://call/\(id)-moved?t=724") })
        XCTAssertEqual(listing(b.callDirectory(id)), theirs, "the meeting that was there is untouched")

        // An id that left this profile counts as taken.
        let (_, b2, _) = try arrive { b in
            var gone = MoveOut(callID: self.id, to: "default", started: self.t0)
            gone.state = .done
            try gone.save(b)
        }
        XCTAssertEqual(intake(b2).run(), [id + "-moved"])

        // Both names taken: refused, and nothing changes in Audio or Chats.
        let (_, b3, _) = try arrive { b in
            for i in [self.id, self.id + "-moved"] {
                try FileManager.default.createDirectory(at: b.callDirectory(i), withIntermediateDirectories: true)
                try CallRecord(id: i, platform: .zoom, bundleID: "us.zoom.xos", start: self.t0, end: self.t0, status: .written).save(to: b.callDirectory(i))
            }
        }
        let audio = listing(b3.audio)
        XCTAssertEqual(intake(b3).run(), [])
        XCTAssertEqual(claimed(b3)?.intake, .refused)
        XCTAssertEqual(claimed(b3)?.refusal, .idTaken)
        XCTAssertEqual(listing(b3.audio), audio)
        XCTAssertTrue(ChatStore(directory: b3.chats).all().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: MoveMarker.folder(id, in: b3).appendingPathComponent("call/call.json").path))
    }

    func testARecordThisBuildCannotReadIsRefused() throws {
        let (_, b, _) = try arrive()
        let call = MoveMarker.folder(id, in: b).appendingPathComponent("call/call.json")
        var text = try String(contentsOf: call, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"zoom\"", with: "\"holo\"")
        try text.write(to: call, atomically: true, encoding: .utf8)
        XCTAssertEqual(intake(b).run(), [])
        XCTAssertEqual(claimed(b)?.refusal, .unreadable)

        let (_, b2, _) = try arrive()
        let audio = MoveMarker.folder(id, in: b2).appendingPathComponent("call/recording.m4a")
        let h = try FileHandle(forWritingTo: audio)
        try h.truncate(atOffset: UInt64(MoveCopy.size(audio)! - 1))
        try h.close()
        XCTAssertEqual(intake(b2).run(), [])
        XCTAssertEqual(claimed(b2)?.refusal, .notWhole)
        XCTAssertTrue(listing(b2.audio).isEmpty)
    }

    /// Each sub-step of the claim, the decision, both halves of the take-in, the check, and `taken`, as the end of the
    /// process; then a new intake runs. At every stop: A is as before, and the meeting is whole in A (it never leaves A
    /// here). After the next run: B holds it once, its chats once, its voice once, and `taken` with every file checked.
    func testAStopAtEverySubStepOfTheIntakeIsFinishedByTheNextRun() throws {
        let counter = StopAt()
        do {
            let (_, b, _) = try arrive()
            _ = intake(b, stop: counter.step).run()
        }
        let total = counter.seen.count
        XCTAssertGreaterThan(total, 6, "\(counter.seen)")
        var reference: CallRecord?
        for n in 0..<total {
            let (a, b, _) = try arrive()
            let before = listing(a.root)
            let stop = StopAt(n)
            XCTAssertEqual(intake(b, stop: stop.step).run(), [], "stop \(n) (\(stop.seen.last ?? ""))")
            XCTAssertEqual(listing(a.root), before, "stop \(n): A changed")
            XCTAssertEqual(intake(b).run(), [id], "stop \(n) (\(stop.seen.last ?? "")): the next run finishes")
            let names = try FileManager.default.contentsOfDirectory(atPath: b.audio.path)
            XCTAssertEqual(names, [id], "stop \(n)")
            XCTAssertEqual(Set(listing(b.callDirectory(id)).keys), ["call.json", "me.caf", "them.caf", "recording.m4a", "frames.json",
                                                                     "frames/000012000.heic"], "stop \(n): no file of the take-in went into Audio")
            let r = try CallRecord.load(from: b.callDirectory(id))
            if let reference { XCTAssertEqual(r, reference, "stop \(n)") } else { reference = r }
            XCTAssertEqual(ChatStore(directory: b.chats).all().count, 1, "stop \(n)")
            XCTAssertTrue(claimed(b)?.heldWhole ?? false, "stop \(n)")
            let library = VoiceLibrary(directory: b.voices)
            XCTAssertEqual(library.profiles.first { $0.name == "Sam Carter" }?.embeddings.count, 1, "stop \(n)")
        }
    }

    func testTheIntakeWaits() throws {
        let (_, b, _) = try arrive()
        let library = VoiceLibrary(directory: b.voices)
        let noIdentity = MoveIntake(paths: b, me: work, library: library, ownerName: { "Avery Webb" }, voiceFingerprints: { true })
        let before = listing(b.root)
        XCTAssertEqual(noIdentity.step(id), .wait)
        XCTAssertEqual(listing(b.root), before)
        // Its own move of this id that is not done: wait.
        var mine = MoveOut(callID: id, to: "default", started: t0)
        mine.state = .waiting
        try mine.save(b)
        XCTAssertEqual(intake(b).step(id), .wait)
        mine.state = .done
        try mine.save(b)
        XCTAssertEqual(intake(b).step(id), .claim)
    }

    func testAMarkerForAnotherProfileIsNeverTakenIn() throws {
        let (_, b, _) = try arrive()
        let other = MoveIntake(paths: b, me: "5e6f7a8b", library: VoiceLibrary(directory: b.voices), ownerName: { "" }, voiceFingerprints: { false })
        XCTAssertEqual(other.step(id), .nothing)
        XCTAssertEqual(other.run(), [])
    }

    func testAPartOrAFolderWithNoMarkerIsNeverTakenIn() throws {
        let b = temp()
        try b.ensureDirectories()
        for name in ["x.token.part", "y", "z"] { try FileManager.default.createDirectory(at: b.incoming.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: b.incoming.appendingPathComponent("z/\(MoveMarker.cancelledName)"))
        XCTAssertFalse(MoveIntake.hasWork(b))
        XCTAssertEqual(intake(b).waiting(), [])
        XCTAssertEqual(intake(b).run(), [])
    }

    func testAnotherVolumeRefusesAndUndoesTheFirstHalf() throws {
        let (_, b, _) = try arrive()
        let i = MoveIntake(paths: b, me: work, library: { let l = VoiceLibrary(directory: b.voices)
            l.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices)); return l }(),
                           ownerName: { "Avery Webb" }, voiceFingerprints: { true }, rename: { from, to in
            to.hasPrefix(b.audio.path) ? EXDEV : MoveFiles.exclusive(from, to)
        })
        XCTAssertEqual(i.run(), [])
        XCTAssertEqual(claimed(b)?.intake, .refused)
        XCTAssertTrue(listing(b.audio).isEmpty)
        XCTAssertTrue(ChatStore(directory: b.chats).all().isEmpty, "the chats of the first half are gone")
        XCTAssertTrue(VoiceLibrary(directory: b.voices).profiles.allSatisfy { $0.embeddings.isEmpty }, "the voices it learned are gone")
    }

    /// A name that the target's own library changed: the arrival is `identified`, and the new summary is made by the
    /// target's pipeline with its own service, never at the take-in and never by the first profile.
    func testTheNewSummaryIsTheTargetsOwnStep() async throws {
        let (a, b, _) = try arrive(fill: { b in
            let library = VoiceLibrary(directory: b.voices)
            library.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices))
            try library.add((0..<8).map { Float(($0 + 1) % 8) / 8 }, to: "Samuel Carter")
        })
        let before = listing(a.root)
        let summarizerA = FakeSummarizer(), summarizerB = FakeSummarizer()
        XCTAssertEqual(intake(b).run(), [id])
        var r = try CallRecord.load(from: b.callDirectory(id))
        XCTAssertEqual(r.status, .identified)
        XCTAssertEqual(r.speakerNames["them:A"], "Samuel Carter")
        XCTAssertEqual(summarizerB.calls, 0, "the take-in sends nothing")
        let library = VoiceLibrary(directory: b.voices)
        library.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices))
        let pipeline = Pipeline(paths: b, transcriber: FakeTranscriber(), library: library, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: summarizerB, notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        await pipeline.runPending()
        XCTAssertEqual(summarizerB.calls, 1)
        r = try CallRecord.load(from: b.callDirectory(id))
        XCTAssertEqual(r.status, .written)
        let note = try XCTUnwrap(r.markdownPath)
        XCTAssertTrue(note.hasPrefix(b.meetings.path), note)
        let text = try String(contentsOfFile: note, encoding: .utf8)
        XCTAssertTrue(text.components(separatedBy: "\n").contains { $0.hasPrefix("audio: ") && $0.hasSuffix("/Audio/\(id)") })
        XCTAssertEqual(summarizerA.calls, 0)
        XCTAssertEqual(listing(a.root), before, "no file of the first profile changed")
    }

    /// A recorded meeting arrives as `recorded`, with no name, and the target's pipeline transcribes it with its own
    /// service.
    func testARecordedMeetingArrivesForTheTargetsOwnPipeline() async throws {
        let a = temp(), b = temp()
        try a.ensureDirectories()
        try b.ensureDirectories()
        let dir = a.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, 400)])
        let start = Date(timeIntervalSince1970: 1_793_520_000)
        try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start + 1800, status: .recorded).save(to: dir)
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        _ = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0)
        try MoveCopy.publish(id, token: token, incoming: b.incoming)

        XCTAssertEqual(intake(b).run(), [id])
        var r = try CallRecord.load(from: b.callDirectory(id))
        XCTAssertEqual(r.status, .recorded)
        XCTAssertTrue(r.speakerNames.isEmpty)
        XCTAssertNil(r.moveTo)
        let transcriber = FakeTranscriber()
        transcriber.result = [
            .me: [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Where is the zebra?")],
            .them: [Utterance(track: .them, speakerLabel: "A", start: 11, end: 20, text: "It left on Friday.")],
        ]
        let library = VoiceLibrary(directory: b.voices)
        library.identity = VoiceIdentity(people: PeopleStore(directory: b.people), samples: VoiceSampleStore(directory: b.voices))
        let pipeline = Pipeline(paths: b, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        await pipeline.runPending()
        XCTAssertFalse(transcriber.calls.isEmpty, "the target's own transcription service")
        r = try CallRecord.load(from: b.callDirectory(id))
        XCTAssertEqual(r.status, .written)
    }
}
