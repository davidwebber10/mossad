import XCTest
@testable import MossadCore

/// "This call is for": from the choice of another profile, nothing of the call goes to a provider of this one.
final class MoveAfterCallTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingIsSentAfterTheChoice() {
        // Each kind of send, before the choice and after it.
        let table: [(MoveAfterCall.Send, here: Bool, other: Bool, back: Bool)] = [
            (.liveTranscript, true, false, false),
            (.liveTitle, true, false, false),
            (.livePoints, true, false, false),
            (.liveChat, true, false, false),
            (.currentCall, true, false, false),
            (.chatSummary, true, false, true),
            (.pipeline, true, false, true),
        ]
        XCTAssertEqual(Set(table.map(\.0)), Set(MoveAfterCall.Send.allCases))
        for (send, here, other, back) in table {
            XCTAssertEqual(MoveAfterCall.allows(send, .here), here, "\(send) here")
            XCTAssertEqual(MoveAfterCall.allows(send, .other(work)), other, "\(send) other")
            XCTAssertEqual(MoveAfterCall.allows(send, .backHere), back, "\(send) back")
        }
    }

    func testTheChoiceCanBeTakenBack() {
        let d = Profile.defaultID
        XCTAssertEqual(MoveAfterCall.next(.here, picked: work, active: d), .other(work))
        XCTAssertEqual(MoveAfterCall.next(.other(work), picked: d, active: d), .backHere)
        XCTAssertEqual(MoveAfterCall.next(.backHere, picked: d, active: d), .backHere)
        XCTAssertEqual(MoveAfterCall.next(.here, picked: d, active: d), .here)
        XCTAssertEqual(MoveAfterCall.next(.backHere, picked: work, active: d), .other(work))
        XCTAssertEqual(MoveAfterCall.next(.other(work), picked: "9f9f9f9f", active: d), .other("9f9f9f9f"))
        // The mark the record keeps for each choice.
        XCTAssertNil(MoveAfterCall.Choice.here.moveTo)
        XCTAssertEqual(MoveAfterCall.Choice.other(work).moveTo, work)
        XCTAssertNil(MoveAfterCall.Choice.backHere.moveTo)
        XCTAssertEqual(MoveAfterCall.choice(of: nil), .here)
        XCTAssertEqual(MoveAfterCall.choice(of: work), .other(work))
    }

    func testTheReasonTheLiveTranscriptIsOff() {
        XCTAssertNil(MoveAfterCall.liveOff(.here))
        XCTAssertEqual(MoveAfterCall.liveOff(.other(work)), .forOtherProfile)
        XCTAssertEqual(MoveAfterCall.liveOff(.backHere), .afterOtherProfile)
        XCTAssertEqual(LiveOffReason.forOtherProfile.text, "This call is for another profile, so nothing of it is sent from here.")
        XCTAssertEqual(LiveOffReason.forOtherProfile.panelText,
                       "This call is for another profile, so Mossad cannot answer during the call. The recording is safe, and that profile writes the notes.")
        XCTAssertEqual(LiveOffReason.afterOtherProfile.text, "The live transcript stays off for the rest of this call.")
        XCTAssertEqual(LiveOffReason.afterOtherProfile.panelText,
                       "The live transcript stays off for the rest of this call, so Mossad cannot answer during the call. The recording is safe, and the full notes come after the call.")
        XCTAssertNil(LiveOffReason.forOtherProfile.fix)
        XCTAssertNil(LiveOffReason.afterOtherProfile.fix)
    }

    private func registry() -> ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work"))
        var old = Profile(id: "5e6f7a8b", name: "Old", color: .green, root: "~/Mossad Old")
        old.removing = true
        r.profiles.append(old)
        return r
    }

    func testThePanelsMenu() throws {
        let d = Profile.defaultID
        XCTAssertNil(MoveAfterCall.menu(ProfileRegistry(), active: d, choice: .here), "one profile: no row")
        var one = ProfileRegistry()
        var gone = Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work")
        gone.removing = true
        one.profiles.append(gone)
        XCTAssertNil(MoveAfterCall.menu(one, active: d, choice: .here), "one live profile: no row")
        let reg = registry()
        let here = try XCTUnwrap(MoveAfterCall.menu(reg, active: d, choice: .here))
        XCTAssertEqual(MoveAfterCall.Menu.title, "This call is for")
        XCTAssertEqual(here.rows.map(\.name), [reg.profiles[0].name, "Work"])
        XCTAssertEqual(here.rows.map(\.chosen), [true, false])
        XCTAssertNil(here.note)
        let other = try XCTUnwrap(MoveAfterCall.menu(reg, active: d, choice: .other(work)))
        XCTAssertEqual(other.rows.map(\.chosen), [false, true])
        XCTAssertEqual(other.note, "“Work” writes the notes. Nothing more of this call is sent from “\(reg.profiles[0].name)”.")
        let back = try XCTUnwrap(MoveAfterCall.menu(reg, active: d, choice: .backHere))
        XCTAssertEqual(back.rows.map(\.chosen), [true, false])
        XCTAssertEqual(back.note, "The live transcript stays off for the rest of this call.")
        // A target that left the registry during the call: no row is chosen for it, and the note names no profile.
        let lost = try XCTUnwrap(MoveAfterCall.menu(reg, active: d, choice: .other("9f9f9f9f")))
        XCTAssertEqual(lost.rows.map(\.chosen), [false, false])
    }

    func testTheEndOfAMarkedCall() {
        XCTAssertEqual(MoveAfterCall.atEnd(nil, targets: [work]), .nothing)
        var r = fullRecord()
        r.status = .recorded
        r.moveTo = nil
        XCTAssertEqual(MoveAfterCall.atEnd(r, targets: [work]), .process)
        r.moveTo = work
        XCTAssertEqual(MoveAfterCall.atEnd(r, targets: [work]), .move(to: work))
        r.moveTo = "9f9f9f9f"
        XCTAssertEqual(MoveAfterCall.atEnd(r, targets: [work]), .hold)
        XCTAssertEqual(MoveAfterCall.atEnd(r, targets: []), .hold)
    }

    func testOneProfileChangesNothing() {
        // With one profile no row shows, the choice stays `.here`, and every send is allowed as before.
        XCTAssertNil(MoveAfterCall.menu(ProfileRegistry(), active: Profile.defaultID, choice: .here))
        for send in MoveAfterCall.Send.allCases { XCTAssertTrue(MoveAfterCall.allows(send, .here)) }
        var r = fullRecord()
        r.status = .recorded
        r.moveTo = nil
        XCTAssertEqual(MoveAfterCall.atEnd(r, targets: []), .process)
    }

    // MARK: The recorder

    final class Box: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

    private func recorder(_ paths: Paths, clock: Box) -> CallRecorder {
        let me = FakeSource()
        me.seconds = 90
        return CallRecorder(paths: paths, makeThem: { _ in FakeSource() }, makeMe: { me }, clock: { clock.now },
                     captureClock: .following { clock.now }, systemAudioAllowed: { true }, micAllowed: { true }, freeBytes: { nil },
                     silenceMuted: { r, dir in try MutedAudio.apply(to: &r, in: dir) })
    }

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveAfterCallTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let p = Paths(root: url)
        try? p.ensureDirectories()
        return p
    }

    func testTheRecorderKeepsTheChoiceOnTheRecord() throws {
        let paths = temp()
        let clock = Box(t0)
        let rec = recorder(paths, clock: clock)
        let id = try rec.beginManual(at: t0)
        rec.setMoveTarget(work, forCall: id)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).moveTo, work, "saved at once")
        rec.setMoveTarget(nil, forCall: "20200101-000000")
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).moveTo, work, "another call's id changes nothing")
        rec.pause()
        rec.resume()
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).moveTo, work, "a pause and a resume keep it")
        rec.setMoveTarget(nil, forCall: id)
        XCTAssertNil(try CallRecord.load(from: paths.callDirectory(id)).moveTo)
        rec.setMoveTarget(work, forCall: id)
        clock.now = t0.addingTimeInterval(600)
        let ended = try XCTUnwrap(rec.end(at: clock.now, trimTo: nil, byPerson: true))
        XCTAssertEqual(ended.status, .recorded)
        XCTAssertEqual(ended.moveTo, work)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).moveTo, work)
    }

    func testACrashKeepsTheChoice() throws {
        let paths = temp()
        let id = "20261101-100000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0, status: .recording)
        r.moveTo = work
        try r.save(to: dir)
        for track in [Track.me, .them] { try writeSegments(dir.appendingPathComponent(track.fileName), total: 90, [(0, 80, 200)]) }
        let queue = ProcessingQueue(paths: paths)
        _ = queue.recoverInterrupted()
        let after = try CallRecord.load(from: dir)
        XCTAssertEqual(after.status, .recorded)
        XCTAssertEqual(after.moveTo, work)
        XCTAssertFalse(queue.pending(now: t0.addingTimeInterval(3600)).contains { $0.id == id }, "the queue does not hold it")
        XCTAssertEqual(MoveAfterCall.atEnd(after, targets: [work]), .move(to: work))
    }
}
