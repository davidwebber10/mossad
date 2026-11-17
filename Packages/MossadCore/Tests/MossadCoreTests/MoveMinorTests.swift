import XCTest
@testable import MossadCore

/// The final review's minor findings that have a pure rule.
final class MoveMinorTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, _ status: CallStatus = .recorded, moveTo: String? = "1a2b3c4d") -> CallRecord {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 1800, status: status)
        r.moveTo = moveTo
        return r
    }

    /// m1: a held call (its reason kept) stays held at each look, also the first one after a launch.
    func testAHeldCallDoesNotStartItsMoveAgain() {
        let rs = [record("a"), record("b"), record("c", moveTo: nil), record("d", .written), record("e"), record("f", moveTo: "9f9f9f9f")]
        let starts = MoveAfterCall.startsAtLook(rs, moving: ["e"], held: ["b"], recording: nil, targets: [work])
        XCTAssertEqual(starts.map(\.callID), ["a"])
        XCTAssertEqual(starts.first?.to, work)
        XCTAssertEqual(MoveAfterCall.startsAtLook(rs, moving: [], held: [], recording: "a", targets: [work]).map(\.callID), ["b", "e"])
    }

    /// m2: a call marked during its recording with no ledger and no reason waits for the owner, with a way out.
    func testAMarkedCallWithNoMoveIsHeld() {
        let row = MoveShow.row(record(id), move: nil, name: "Work", copied: nil, reach: .open, held: nil, now: t0)
        XCTAssertEqual(row, MoveShow.Row(text: "The move to “Work” has not started. Mossad does not process it until you choose.", cancels: false, held: true))
        XCTAssertEqual(MoveShow.row(record(id, .failed), move: nil, name: "Work", copied: nil, reach: .open, held: nil, now: t0)?.held, true)
        // A call that still records has no row's acts.
        XCTAssertEqual(MoveShow.row(record(id, .recording), move: nil, name: "Work", copied: nil, reach: .open, held: nil, now: t0)?.held, false)
    }

    /// m7: the end reads the owner's latest choice, not only the record that a late write missed.
    func testTheEndReadsTheLatestChoice() {
        let plain = record(id, moveTo: nil)
        XCTAssertEqual(MoveAfterCall.settled(plain, latest: .other(work)).moveTo, work)
        XCTAssertEqual(MoveAfterCall.atEnd(MoveAfterCall.settled(plain, latest: .other(work)), targets: [work]), .move(to: work))
        let marked = record(id)
        XCTAssertNil(MoveAfterCall.settled(marked, latest: .backHere).moveTo)
        XCTAssertEqual(MoveAfterCall.atEnd(MoveAfterCall.settled(marked, latest: .backHere), targets: [work]), .process)
        // No choice in memory (one profile, or a launch): the record decides, as before.
        XCTAssertEqual(MoveAfterCall.settled(marked, latest: nil), marked)
        XCTAssertEqual(MoveAfterCall.settled(plain, latest: nil), plain)
    }

    /// m12: what the choice stops at once.
    func testWhatTheChoiceStops() {
        XCTAssertEqual(MoveAfterCall.stops(.other(work)), [.liveStreams, .liveFile, .liveChatAnswer])
        XCTAssertEqual(MoveAfterCall.stops(.backHere), [])
        XCTAssertEqual(MoveAfterCall.stops(.here), [])
        XCTAssertEqual(MoveAfterCall.stops(.guessed(work)), [.liveStreams, .liveFile, .liveChatAnswer])
    }

    /// m12, the second net: the app stops what the rule lists, and carries a choice to a new recording before any send.
    func testTheAppStopsWhatTheRuleLists() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let moves = try String(contentsOf: app.appendingPathComponent("AppController+Moves.swift"), encoding: .utf8)
        XCTAssertTrue(moves.contains("MoveAfterCall.stops(next)"))
        for stop in [".liveStreams) { stopLive() }", ".liveFile) { live.removeFile(", ".liveChatAnswer) { liveChatSessions[callID]?.stop() }"] {
            XCTAssertTrue(moves.contains(stop), stop)
        }
        let controller = try String(contentsOf: app.appendingPathComponent("AppController.swift"), encoding: .utf8)
        // In `show(.started)`, both found from the start of the case: the carry comes first.
        let started = try XCTUnwrap(controller.range(of: "case .started(let platform, let bundleID, let at):"))
        let rest = controller[started.upperBound...]
        let carry = try XCTUnwrap(rest.range(of: "carryChoice(to:"))
        let live = try XCTUnwrap(rest.range(of: "startLive(reset: true)"))
        XCTAssertLessThan(carry.lowerBound, live.lowerBound)
        XCTAssertTrue(controller.contains("assert(AppIdentity.current.isPreview || carry.decided == CallRecorder.callID(for: since)"))
    }

    /// m6: the leftovers in `Incoming` are cleaned at most once an hour, with or without work.
    func testTheCleanUpIsHourly() {
        XCTAssertTrue(MoveIntake.cleanUpDue(last: nil, now: t0))
        XCTAssertFalse(MoveIntake.cleanUpDue(last: t0, now: t0 + 3599))
        XCTAssertTrue(MoveIntake.cleanUpDue(last: t0, now: t0 + 3600))
    }

    /// m5: a removed name matches whole fields only, and a plan of a newer build is never written again.
    func testTheMigrationFilesMatchWholeNames() throws {
        let sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam", origin: .voiceNaming, at: t0)
        var plan = PeopleMigration.Plan(made: t0, basis: "b", changes: true, people: [], samples: [], report: MigrationReport())
        plan.people = [sam]
        plan.report.notes = ["Sam", "Samuel Lee was merged", "Sam was merged"]
        let kept = PeopleMigration.forgetting(plan, callID: id, people: ["p-sam"])
        XCTAssertEqual(kept.report.notes, ["Samuel Lee was merged"])
        // n7: a name that is a common word takes only the lines with it as a name.
        var will = plan
        will.people = [Person(id: PersonID(rawValue: "p-will"), displayName: "Will", origin: .voiceNaming, at: t0)]
        will.report.notes = ["Will was merged", "It will read the plan again"]
        XCTAssertEqual(PeopleMigration.forgetting(will, callID: id, people: ["p-will"]).report.notes, ["It will read the plan again"])
    }

    func testANewerPlanIsNotWrittenAgain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveMinorTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let paths = Paths(root: url)
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        var plan = PeopleMigration.Plan(made: t0, basis: "b", changes: true, people: [], samples: [], report: MigrationReport())
        plan.version = PeopleMigration.Plan.currentVersion + 1
        plan.report.notes = ["The call \(id) was read"]
        let data = try JSONEncoder.callRecord.encode(plan)
        let file = paths.people.appendingPathComponent(PeopleMigration.planName)
        try data.write(to: file)
        try PeopleMigration.forget(callID: id, people: [], paths: paths)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
