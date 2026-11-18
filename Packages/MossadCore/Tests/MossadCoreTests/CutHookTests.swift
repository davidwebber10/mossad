import XCTest
@testable import MossadCore

/// The one path of the cut by a recording's marks (`Pipeline.cutIfNeeded`): for the end of a call, the launch, and a
/// worker. A recording marked for another profile is cut, and each part is held for the owner.
final class CutHookTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)
    private var id: String { CallRecorder.callID(for: t0) }
    private let length: TimeInterval = 150
    private let cutAt: TimeInterval = 90
    private let work = "1a2b3c4d"

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CutHookTests-\(UUID().uuidString)")
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

    private func pipeline(_ a: Paths, events: [CalendarEventInfo] = []) -> Pipeline {
        Pipeline(paths: a, transcriber: FakeTranscriber(), library: library(a), embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(events: events),
                 summarizer: nil, notify: { _ in }, now: { [t0] in t0 + 7200 }, ownerName: "Avery Webb")
    }

    /// A recorded call of 150 s with both tracks and the given marks.
    private func recorded(_ a: Paths, marks: [CallMark]?, moveTo: String? = nil, change: (inout CallRecord) -> Void = { _ in }) throws {
        let dir = a.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AudioCutTests.writeTrack(dir.appendingPathComponent("me.caf"), frames: Int(length * 16_000))
        try AudioCutTests.writeTrack(dir.appendingPathComponent("them.caf"), frames: Int(length * 16_000))
        var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + length, status: .recorded)
        r.meetingID = "aaa-bbbb-ccc"
        r.callMarks = marks
        r.moveTo = moveTo
        change(&r)
        try r.save(to: dir)
    }

    private var sureMark: CallMark { CallMark(at: cutAt, time: t0 + cutAt, link: "ddd-eeee-fff", platform: .meet, source: .tabs, sure: true) }
    private var titleMark: CallMark { CallMark(at: cutAt, time: t0 + cutAt, link: nil, platform: .meet, source: .title, sure: false, titleKey: "k") }

    private func load(_ a: Paths, _ id: String) -> CallRecord? { try? CallRecord.load(from: a.callDirectory(id)) }

    func testASureMarkCutsAndGivesThePartsToProcess() async throws {
        let a = temp()
        try recorded(a, marks: [sureMark])
        let ids = await pipeline(a).cutIfNeeded(callID: id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNil(load(a, id), "the original is gone")
        XCTAssertEqual(ids.compactMap { load(a, $0)?.cutFrom }, [id, id])
        XCTAssertEqual(ids.compactMap { load(a, $0) }.map { CutPlan.waits($0) }, [false, false], "a part is never cut again")
    }

    func testNoCutIsDecidedOnceAndTheRecordingStaysOne() async throws {
        let a = temp()
        try recorded(a, marks: [titleMark])
        let p = pipeline(a)
        let ids = await p.cutIfNeeded(callID: id)
        XCTAssertEqual(ids, [id])
        XCTAssertEqual(load(a, id)?.cutChecked, true)
        XCTAssertEqual(load(a, id)?.callMarks, [titleMark], "the marks stay as they were")
        XCTAssertFalse(CutPlan.waits(try XCTUnwrap(load(a, id))))
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999).map(\.id), [id])
    }

    func testARefusedCutIsRememberedAndTheRecordingIsProcessedAsOne() async throws {
        let a = temp()
        // The silence of a mute is still to be written: the cut refuses.
        try recorded(a, marks: [sureMark]) { $0.mutedAudioPending = true }
        let before = try Data(contentsOf: a.callDirectory(id).appendingPathComponent("me.caf"))
        let p = pipeline(a)
        let first = await p.cutIfNeeded(callID: id)
        XCTAssertEqual(first, [id])
        XCTAssertEqual(load(a, id)?.cutChecked, true)
        XCTAssertEqual(try Data(contentsOf: a.callDirectory(id).appendingPathComponent("me.caf")), before)
        // At a later launch nothing is decided or tried again.
        var r = try XCTUnwrap(load(a, id))
        r.mutedAudioPending = false
        try r.save(to: a.callDirectory(id))
        let again = await pipeline(a).cutIfNeeded(callID: id)
        XCTAssertEqual(again, [id])
        XCTAssertNotNil(load(a, id), "never cut")
    }

    func testARecordingWithNoMarkIsAsBefore() async throws {
        let a = temp()
        try recorded(a, marks: nil)
        let ids = await pipeline(a).cutIfNeeded(callID: id)
        XCTAssertEqual(ids, [id])
        XCTAssertNil(load(a, id)?.cutChecked, "nothing is written on a recording with no mark")
    }

    func testTheCommandStillRefusesAMarkedRecording() async throws {
        let a = temp()
        try recorded(a, marks: [sureMark], moveTo: work)
        do {
            _ = try await pipeline(a).cut(callID: id, at: [Cut(at: cutAt, link: nil)])
            XCTFail("refused")
        } catch let error as Pipeline.CutError {
            XCTAssertEqual(error, .refused("The meeting is marked for another profile."))
        }
    }

    /// A recording marked for another profile with a cut: each part is held, nothing starts by itself, and the owner's
    /// choice on one part changes that part only.
    func testTheCutPartsOfAMarkedRecordingAreHeld() async throws {
        let a = temp(), b = temp()
        try recorded(a, marks: [sureMark], moveTo: work)
        // The guess that held the recording.
        try MoveEnded(callID: id, to: work, why: .notSure, afterCall: true, at: t0).save(a)
        let p = pipeline(a)
        let ids = await p.cutIfNeeded(callID: id)
        XCTAssertEqual(ids.count, 2)
        guard ids.count == 2 else { return }
        let parts = ids.compactMap { load(a, $0) }
        XCTAssertEqual(parts.map(\.moveTo), [work, work], "each part keeps the mark")
        let held = MoveEnded.all(a)
        XCTAssertEqual(held.map(\.callID).sorted(), ids.sorted(), "each part has its held reason; the original's went")
        XCTAssertTrue(held.allSatisfy { $0.afterCall && $0.why == .notSure && $0.to == work })
        XCTAssertEqual(MoveAfterCall.startsAtLook(parts, moving: [], held: Set(held.filter(\.afterCall).map(\.callID)), recording: nil,
                                                  targets: [work]).map(\.callID), [], "no look starts a move of a part")
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999), [], "no step processes a held part")

        // "Process here" on the first part: the mark goes and its reason goes; only that part is processed.
        let marked = await p.setMoveTarget(callID: ids[0], nil)
        XCTAssertTrue(marked)
        MoveEnded.shown(ids[0], paths: a)
        XCTAssertEqual(ProcessingQueue(paths: a).pending(now: t0 + 9999).map(\.id), [ids[0]])
        XCTAssertEqual(load(a, ids[1])?.moveTo, work)

        // "Move to" on the second part: a move of that part only.
        let lib = library(a)
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in }, backup: { _ in true },
                                          removeFolder: { id, to in await p.removeMoved(callID: id, target: to) })
        try b.ensureDirectories()
        let source = MoveSource(.init(paths: a, profileID: "default", pipeline: p, library: lib, ownerName: { "Avery Webb" },
                                      target: { _ in .paths(b) }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                      now: { [t0] in t0 + 7200 }))
        let started = await source.start(ids[1], to: work, afterCall: true)
        XCTAssertEqual(started, .started)
        XCTAssertNotNil(MoveOut.load(ids[1], paths: a))
        XCTAssertNil(MoveOut.load(ids[0], paths: a), "the other part does not move")
        XCTAssertNil(load(a, ids[0])?.moveTo)
    }

    func testALaunchDecidesAMarkedRecordingAndHoldsItsParts() async throws {
        let a = temp()
        try recorded(a, marks: [sureMark], moveTo: work)
        await pipeline(a).runPending()
        let parts = (try FileManager.default.contentsOfDirectory(atPath: a.audio.path)).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(parts.count, 2)
        XCTAssertFalse(parts.contains(id))
        XCTAssertEqual(parts.compactMap { load(a, $0)?.moveTo }, [work, work])
        XCTAssertEqual(parts.compactMap { load(a, $0)?.status }, [.recorded, .recorded], "held: not processed")
        XCTAssertEqual(MoveEnded.all(a).map(\.callID).sorted(), parts)
    }

    func testARolledBackCutOfAMarkedRecordingLeavesNoHeldPart() async throws {
        let a = temp()
        try recorded(a, marks: [sureMark], moveTo: work)
        let p = pipeline(a)
        await p.setCutStop { point in if point == "held saved" { throw Boom() } }
        _ = try? await p.cut(callID: id, at: [Cut(at: cutAt, link: nil)], holdingMarked: true)
        await p.setCutStop(nil)
        await p.finishInterruptedCuts()
        XCTAssertNotNil(load(a, id), "the original is whole")
        XCTAssertEqual(MoveEnded.all(a).map(\.callID), [], "no held reason for a part that never was")
    }

    func testThePageOfACutRecordingShowsItsFirstPart() {
        func r(_ id: String, _ s: TimeInterval, from: String?) -> CallRecord {
            var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: t0 + s, end: t0 + s + 60, status: .recorded)
            r.cutFrom = from
            return r
        }
        let records = [r("b", 100, from: "o"), r("a", 0, from: "o"), r("c", 0, from: nil)]
        XCTAssertEqual(CutRecord.firstPart(of: "o", in: records), "a")
        XCTAssertNil(CutRecord.firstPart(of: "c", in: records))
    }
}
