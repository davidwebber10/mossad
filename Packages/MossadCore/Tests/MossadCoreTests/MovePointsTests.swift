import XCTest
@testable import MossadCore

/// The points for next time of a meeting go with it to the other profile: in the copy as one checked file, taken in by
/// the target after its file check, once, and emptied in the first profile only when the target took the meeting.
final class MovePointsTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let token = "aaaa0001"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let made = Date(timeIntervalSince1970: 1_793_520_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MovePointsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ p: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: p.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: p.people), samples: VoiceSampleStore(directory: p.voices))
        return l
    }

    private func intake(_ b: Paths, stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveIntake {
        MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true }, stop: stop, now: { [t0] in t0 })
    }

    private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// The first profile's book: two points of the meeting (one discussed in it), one of a series, one for a person.
    private func book() -> NextTimeBook {
        let detail = MeetingDetail(title: "Zebra budget", start: made, end: made + 1800, event: NextTimeMeeting.event("uid-1"), people: ["p-sam"], invited: 1)
        var b = NextTimeBook()
        var open = NextTimePoint(text: "Ask about the zebra budget", rank: 1, created: made - 600)
        open.id = uuid(1)
        open.meeting = NextTimeMeeting(detail, calls: [id])
        var discussed = NextTimePoint(text: "The crossing", rank: 2, created: made - 500)
        discussed.id = uuid(2)
        discussed.meeting = NextTimeMeeting(detail, calls: [id])
        discussed.done = .init(callID: id, at: 20, quote: "the zebra crossing is closed", date: made + 1900, byOwner: false)
        var series = NextTimePoint(text: "Hiring", rank: 1, created: made - 400)
        series.id = uuid(3)
        series.seriesID = "cal:series-1"
        series.seriesKeys = ["cal:series-1"]
        series.carried = [id]
        var person = NextTimePoint(text: "Ask Sam about the trip", personID: "p-sam", personName: "Sam Carter", rank: 1, created: made - 300)
        person.id = uuid(4)
        b.points = [open, discussed, series, person]
        b.checked = [id]
        return b
    }

    private func world(points: Bool = true) throws -> (a: Paths, b: Paths) {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        if points { try book().save(to: a.nextTime) }
        try b.ensureDirectories()
        return (a, b)
    }

    private func arrive(points: Bool = true, fill: (Paths) throws -> Void = { _ in }) throws -> (a: Paths, b: Paths, marker: MoveMarker) {
        let (a, b) = try world(points: points)
        try fill(b)
        let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
        let marker = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0)
        try MoveCopy.publish(id, token: token, incoming: b.incoming)
        return (a, b, marker)
    }

    private func claimed(_ b: Paths) -> MoveMarker? {
        if case .claimed(let m) = MoveMarker.look(MoveMarker.folder(id, in: b)) { return m }
        return nil
    }

    private func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    // MARK: The copy

    func testAMoveWithNoPointsWritesWhatItWroteBefore() throws {
        for withBook in [false, true] {
            let (a, b) = try world(points: false)
            if withBook {
                // Only points that stay: no file either.
                var only = book()
                only.points = only.points.filter { $0.meeting == nil }
                try only.save(to: a.nextTime)
            }
            let plan = try MoveCopy.plan(id, in: a, to: work, owner: OwnerIdentity(name: "Avery Webb"), fetched: nil)
            XCTAssertNil(plan.points)
            let marker = try MoveCopy.write(plan, from: "default", token: token, incoming: b.incoming, now: t0)
            let part = MoveCopy.part(id, token: token, incoming: b.incoming)
            XCTAssertEqual(names(part), [MoveMarker.callFolder, MoveMarker.chatsFolder, MoveMarker.fileName])
            XCTAssertNil(marker.points)
            let text = try String(contentsOf: part.appendingPathComponent(MoveMarker.fileName), encoding: .utf8)
            XCTAssertFalse(text.contains("points"), text)
            try MoveCopy.publish(id, token: token, incoming: b.incoming)
            XCTAssertEqual(intake(b).run(), [id])
            XCTAssertNil(claimed(b)?.pointIDs)
            XCTAssertFalse(FileManager.default.fileExists(atPath: b.nextTime.appendingPathComponent(NextTimeBook.fileName).path), "the target's book is not written")
        }
    }

    func testThePointsTravelAsOneCheckedFileBesideTheMeeting() throws {
        let (_, b, marker) = try arrive()
        let folder = MoveMarker.folder(id, in: b)
        let file = folder.appendingPathComponent(MovedPoints.fileName)
        let listed = try XCTUnwrap(marker.points)
        XCTAssertEqual(listed.path, MovedPoints.fileName)
        XCTAssertEqual(listed.size, MoveCopy.size(file))
        XCTAssertEqual(listed.sha256, try FileHash.sha256(of: file))
        // Not in `files`: an older target checks every listed file in its `Audio`, and would refuse the meeting.
        XCTAssertFalse(marker.files.contains { $0.path.contains("points") })
        let moved = try XCTUnwrap(MovedPoints.read(file))
        XCTAssertEqual(moved.points.map(\.text), ["Ask about the zebra budget", "The crossing"])
        XCTAssertTrue(moved.checked)
        let text = try String(contentsOf: folder.appendingPathComponent(MoveMarker.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("zebra"), "the marker holds no words of a point")
    }

    // MARK: The take-in

    func testTheTargetAddsThePointsToItsOwnBook() throws {
        let (_, b, _) = try arrive()
        XCTAssertEqual(intake(b).run(), [id])
        let m = try XCTUnwrap(claimed(b))
        XCTAssertEqual(m.intake, .taken)
        let ids = try XCTUnwrap(m.pointIDs).compactMap(UUID.init(uuidString:))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(Set(ids).isDisjoint(with: book().points.map(\.id)), "new ids")
        XCTAssertEqual(names(MoveMarker.folder(id, in: b)), [MoveMarker.claimedName], "the copy of the points goes")
        let taken = try NextTimeBook.load(from: b.nextTime)
        XCTAssertEqual(taken.points.map(\.id), ids)
        XCTAssertEqual(taken.points.map(\.text), ["Ask about the zebra budget", "The crossing"])
        XCTAssertTrue(taken.points.allSatisfy { $0.meeting?.calls == [self.id] && $0.personID == nil && $0.seriesID == nil })
        XCTAssertEqual(taken.points.first?.meeting?.detail?.title, "Zebra budget", "the detail is in this profile's local file")
        XCTAssertNil(taken.points.first?.meeting?.detail?.people)
        XCTAssertEqual(taken.points[1].done, .init(callID: id, at: 20, quote: "the zebra crossing is closed", date: made + 1900, byOwner: false))
        XCTAssertTrue(taken.checked.contains(id))
        let local = try String(contentsOf: b.nextTime.appendingPathComponent(MeetingPointsLocal.fileName), encoding: .utf8)
        XCTAssertTrue(local.contains("Zebra budget"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: b.nextTime.appendingPathComponent(NextTimeBook.fileName)), as: UTF8.self).contains("Zebra budget"))
    }

    func testAnIDTakenHereGivesThePointsTheMovedID() throws {
        let other = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 60, status: .written)
        let (_, b, _) = try arrive { b in
            try FileManager.default.createDirectory(at: b.callDirectory(other.id), withIntermediateDirectories: true)
            try other.save(to: b.callDirectory(other.id))
        }
        XCTAssertEqual(intake(b).run(), [id + "-moved"])
        let taken = try NextTimeBook.load(from: b.nextTime)
        XCTAssertTrue(taken.points.allSatisfy { $0.meeting?.calls == [self.id + "-moved"] })
        XCTAssertEqual(taken.points[1].done?.callID, id + "-moved")
        XCTAssertEqual(taken.checked, [id + "-moved"])
    }

    func testAStopAtEverySubStepAddsEachPointOnce() throws {
        let counter = StopAt()
        do {
            let (_, b, _) = try arrive()
            _ = intake(b, stop: counter.step).run()
        }
        let total = counter.seen.count
        XCTAssertTrue(counter.seen.contains("add the points"), "\(counter.seen)")
        for n in 0..<total {
            let (_, b, _) = try arrive()
            let stop = StopAt(n)
            _ = intake(b, stop: stop.step).run()
            XCTAssertEqual(intake(b).run(), [id], "stop \(n) (\(stop.seen.last ?? ""))")
            let m = try XCTUnwrap(claimed(b))
            XCTAssertEqual(m.intake, .taken, "stop \(n)")
            let taken = try NextTimeBook.load(from: b.nextTime)
            XCTAssertEqual(taken.points.map(\.id.uuidString), m.pointIDs, "stop \(n) (\(stop.seen.last ?? "")): each point once")
        }
    }

    func testAPointsFileThatDoesNotMatchIsRefusedAndNothingIsAdded() throws {
        let (_, b, _) = try arrive()
        let file = MoveMarker.folder(id, in: b).appendingPathComponent(MovedPoints.fileName)
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "zebra", with: "zebrA")
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(intake(b).run(), [])
        XCTAssertEqual(claimed(b)?.refusal, .notWhole)
        XCTAssertTrue(names(b.audio).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.nextTime.appendingPathComponent(NextTimeBook.fileName).path))
    }

    func testAPointsFileOfANewerBuildIsRefusedAsUnreadable() throws {
        let (_, b, _) = try arrive()
        let folder = MoveMarker.folder(id, in: b)
        let file = folder.appendingPathComponent(MovedPoints.fileName)
        var moved = try XCTUnwrap(MovedPoints.read(file))
        moved.version = MovedPoints.currentVersion + 1
        try JSONEncoder.move.encode(moved).write(to: file)
        // The first profile's marker lists the file as it is now: only its version is newer.
        guard case .incoming(var m) = MoveMarker.look(folder) else { return XCTFail() }
        m.points = MoveMarker.File(path: MovedPoints.fileName, size: MoveCopy.size(file)!, sha256: try FileHash.sha256(of: file))
        try m.save(in: folder, claimed: false)
        XCTAssertEqual(intake(b).run(), [])
        XCTAssertEqual(claimed(b)?.refusal, .unreadable)
    }

    func testABookThatCannotTakeThePointsHoldsTheTakeInAndTheFirstProfileKeepsTheMeeting() async throws {
        let (a, b) = try world()
        try FileManager.default.createDirectory(at: b.nextTime, withIntermediateDirectories: true)
        var newer = NextTimeBook()
        newer.version = NextTimeBook.currentVersion + 1
        try JSONEncoder.coach.encode(newer).write(to: b.nextTime.appendingPathComponent(NextTimeBook.fileName))
        let place = Place(.paths(b))
        _ = await source(a, place: place).start(id, to: work)
        for _ in 0..<3 {
            _ = await source(a, place: place).run(id)
            _ = intake(b).run()
        }
        let m = try XCTUnwrap(claimed(b))
        XCTAssertEqual(m.intake, .takingIn)
        XCTAssertEqual(m.waits, .points)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .waiting, "A removes nothing before `taken`")
        XCTAssertEqual(try NextTimeBook.load(from: a.nextTime).visible.count, 4)
        XCTAssertEqual(MoveWords.notFinished("Work", .points), "“Work” took the meeting but has not finished: it cannot save the meeting's points yet. It tries again.")
        // The book reads again: the next look goes on.
        try JSONEncoder.coach.encode(NextTimeBook()).write(to: b.nextTime.appendingPathComponent(NextTimeBook.fileName))
        let later = MoveIntake(paths: b, me: work, library: library(b), ownerName: { "Avery Webb" }, voiceFingerprints: { true },
                               now: { [t0] in t0 + 86_400 })
        XCTAssertEqual(later.run(), [id])
        XCTAssertEqual(try NextTimeBook.load(from: b.nextTime).points.count, 2)
    }

    // MARK: Both halves

    final class Place: @unchecked Sendable {
        var value: MoveRules.TargetPlace
        init(_ v: MoveRules.TargetPlace) { value = v }
    }

    private func source(_ a: Paths, place: Place, stop: @escaping @Sendable (String) throws -> Void = { _ in }) -> MoveSource {
        let lib = library(a)
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            var p = (try? CoachProfile.load(from: a.coach)) ?? CoachProfile()
            change(&p)
            try p.save(to: a.coach)
        }, stopShares: { callID in
            var book = ShareBook.load(from: a.shares)
            book.markStopping(callID: callID)
            try? book.save(to: a.shares)
        }, backup: { r in CloudArchive.rememberDeletes(of: r, paths: a); return true },
        removeFolder: { id, to in await pipeline.removeMoved(callID: id, target: to, stop: stop) })
        return MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                           target: { _ in place.value }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                           now: { [t0] in t0 }, stop: stop))
    }

    private func bytes(_ p: Paths) -> [Data?] {
        [NextTimeBook.fileName, MeetingPointsLocal.fileName].map { try? Data(contentsOf: p.nextTime.appendingPathComponent($0)) }
    }

    func testThePointsGoWithTheMeetingAndTheFirstProfileKeepsNoneOfThem() async throws {
        let (a, b) = try world()
        let place = Place(.paths(b))
        _ = await source(a, place: place).start(id, to: work)
        for _ in 0..<6 {
            _ = await source(a, place: place).run(id)
            _ = intake(b).run()
        }
        _ = await source(a, place: place).run(id)
        XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done)
        let left = try NextTimeBook.load(from: a.nextTime)
        XCTAssertEqual(left.visible.map(\.text), ["Hiring", "Ask Sam about the trip"])
        XCTAssertTrue(left.points.filter { [uuid(1), uuid(2)].contains($0.id) }.allSatisfy(NextTimeBook.forgotten))
        XCTAssertNil(left.points.first { $0.id == uuid(3) }?.carried, "the series point only loses the call")
        let localA = try String(contentsOf: a.nextTime.appendingPathComponent(MeetingPointsLocal.fileName), encoding: .utf8)
        XCTAssertFalse(localA.contains("Zebra budget"), "the first profile's detail goes")
        let taken = try NextTimeBook.load(from: b.nextTime)
        XCTAssertEqual(taken.visible.map(\.text), ["Ask about the zebra budget", "The crossing"])
        XCTAssertEqual(taken.discussed(in: id).map(\.text), ["The crossing"])
    }

    /// One count of sub-steps across both processes: at each, the process that runs ends; then both halves run to the
    /// end. The points are then in the target once each, and the first profile keeps none of them.
    func testAStopAnywhereInEitherHalfNeitherLosesNorDoublesAPoint() async throws {
        let counter = StopAt()
        do {
            let (a, b) = try world()
            let place = Place(.paths(b))
            _ = await source(a, place: place, stop: counter.step).start(id, to: work)
            for _ in 0..<6 {
                _ = await source(a, place: place, stop: counter.step).run(id)
                _ = intake(b, stop: counter.step).run()
            }
            _ = await source(a, place: place, stop: counter.step).run(id)
        }
        let total = counter.seen.count
        XCTAssertTrue(counter.seen.contains("write the points") && counter.seen.contains("add the points"), "\(counter.seen)")
        for n in 0..<total {
            let (a, b) = try world()
            let place = Place(.paths(b))
            let stop = StopAt(n)
            _ = await source(a, place: place, stop: stop.step).start(id, to: work)
            if MoveOut.load(id, paths: a) == nil { _ = await source(a, place: place).start(id, to: work) }
            var stopped = false
            for _ in 0..<6 where !stopped {
                _ = await source(a, place: place, stop: stop.step).run(id)
                stopped = stop.seen.count > n
                if stopped { break }
                _ = intake(b, stop: stop.step).run()
                stopped = stop.seen.count > n
            }
            if !stopped { _ = await source(a, place: place, stop: stop.step).run(id) }
            for _ in 0..<6 {
                _ = await source(a, place: place).run(id)
                _ = intake(b).run()
            }
            _ = await source(a, place: place).run(id)
            let at = "stop \(n) (\(stop.seen.last ?? ""))"
            XCTAssertEqual(MoveOut.load(id, paths: a)?.state, .done, at)
            XCTAssertEqual(try NextTimeBook.load(from: b.nextTime).visible.map(\.text), ["Ask about the zebra budget", "The crossing"], at)
            XCTAssertEqual(try NextTimeBook.load(from: a.nextTime).visible.map(\.text), ["Hiring", "Ask Sam about the trip"], at)
        }
    }

    func testACancelledMoveLeavesThePointsAsTheyWere() async throws {
        let (a, b) = try world()
        let before = bytes(a)
        let place = Place(.paths(b))
        _ = await source(a, place: place).start(id, to: work)
        _ = await source(a, place: place).run(id)
        let cancelled = await source(a, place: place).cancel(id)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(intake(b).run(), [])
        XCTAssertEqual(bytes(a), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.nextTime.appendingPathComponent(NextTimeBook.fileName).path))
    }

    func testARefusedMoveLeavesThePointsAsTheyWere() async throws {
        let (a, b) = try world()
        for i in [id, id + "-moved"] {
            try FileManager.default.createDirectory(at: b.callDirectory(i), withIntermediateDirectories: true)
            try CallRecord(id: i, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0, status: .written).save(to: b.callDirectory(i))
        }
        let before = bytes(a)
        let place = Place(.paths(b))
        _ = await source(a, place: place).start(id, to: work)
        var events: [MoveSource.Event] = []
        for _ in 0..<4 {
            events.append(await source(a, place: place).run(id))
            _ = intake(b).run()
        }
        XCTAssertTrue(events.contains(.cancelled(.refusedIDTaken)), "\(events)")
        XCTAssertEqual(bytes(a), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.nextTime.appendingPathComponent(NextTimeBook.fileName).path))
    }

    // MARK: Words

    func testTheConfirmationSaysThePointsGoOnlyWhenThereAreSome() {
        XCTAssertEqual(MoveWords.leaves("Mossad"), "The meeting leaves “Mossad” with its tasks, its chats, and what Mossad learned from it.")
        XCTAssertEqual(MoveWords.leaves("Mossad", points: 0), MoveWords.leaves("Mossad"))
        XCTAssertEqual(MoveWords.leaves("Mossad", points: 2),
                       "The meeting leaves “Mossad” with its tasks, its chats, its points for next time, and what Mossad learned from it.")
    }
}
