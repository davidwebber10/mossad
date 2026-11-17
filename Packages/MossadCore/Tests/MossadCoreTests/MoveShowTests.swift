import XCTest
@testable import MossadCore

/// What the app shows of a move: the menu, the row, the line, and the answers to the owner's Cancel.
final class MoveShowTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    private func record(_ status: CallStatus = .written, moveTo: String? = nil) -> CallRecord {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 1800, status: status)
        r.moveTo = moveTo
        return r
    }

    private func move(_ state: MoveOut.State, started: Date) -> MoveOut {
        var m = MoveOut(callID: id, to: work, started: started)
        m.state = state
        return m
    }

    private func twoProfiles() -> ProfileRegistry {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: work, name: "Work", color: .blue, root: "~/Mossad Work"))
        return r
    }

    // MARK: One profile: nothing changes

    func testWithOneProfileNothingShows() {
        let one = ProfileRegistry()
        XCTAssertFalse(MoveShow.menuShows(targets: MoveRules.targets(one, active: Profile.defaultID)))
        XCTAssertFalse(MoveRules.looks(mode: .full, liveProfiles: one.live.count))
        // A meeting with no mark and no ledger has no move line and no "Process here".
        for status in [CallStatus.recording, .recorded, .transcribed, .identified, .summarized, .written, .failed] {
            XCTAssertNil(MoveShow.row(record(status), move: nil, name: nil, copied: nil, reach: .open, held: nil, now: t0), "\(status)")
        }
        XCTAssertTrue(MoveShow.menuShows(targets: MoveRules.targets(twoProfiles(), active: Profile.defaultID)))
    }

    // MARK: The row

    func testTheRowWhileTheMoveWaits() {
        let r = record(moveTo: work)
        let fresh = MoveShow.row(r, move: move(.copied, started: t0), name: "Work", copied: nil, reach: .open, held: nil, now: t0 + 5)
        XCTAssertEqual(fresh, MoveShow.Row(text: "Moving to Work…", cancels: true, held: false))
        let copying = MoveShow.row(r, move: move(.copying, started: t0), name: "Work", copied: 0.42, reach: .open, held: nil, now: t0 + 90)
        XCTAssertEqual(copying?.text, "Moving to Work… 42%")
        XCTAssertEqual(copying?.cancels, true)
        let slow = MoveShow.row(r, move: move(.waiting, started: t0), name: "Work", copied: nil, reach: .open, held: nil, now: t0 + 120)
        XCTAssertEqual(slow?.text, "Moving to Work… It arrives when “Work” is next open.")
        XCTAssertEqual(slow?.cancels, true)
    }

    /// A move that waits long says why, when the app can know it.
    func testASlowMoveSaysWhy() {
        let r = record(moveTo: work)
        let w = move(.waiting, started: t0)
        XCTAssertEqual(MoveShow.row(r, move: w, name: "Work", copied: nil, reach: .notSetUp, held: nil, now: t0 + 120)?.text,
                       "Moving to Work… “Work” is not set up yet. It arrives when its setup is done.")
        XCTAssertEqual(MoveShow.row(r, move: w, name: "Work", copied: nil, reach: .unreachable, held: nil, now: t0 + 120)?.text,
                       "Moving to Work… Mossad cannot reach “Work” now. It arrives when Mossad can.")
        XCTAssertEqual(MoveShow.row(r, move: w, name: "Work", copied: nil, reach: .notRunning, held: nil, now: t0 + 120)?.text,
                       "Moving to Work… “Work” is not running now. It arrives when “Work” is next open.")
        // Before the minute: no reason yet, the short line.
        XCTAssertEqual(MoveShow.row(r, move: w, name: "Work", copied: nil, reach: .notSetUp, held: nil, now: t0 + 30)?.text, "Moving to Work…")
    }

    func testCancelShowsOnlyBeforeTheTargetCanHaveIt() {
        let r = record(moveTo: work)
        for state in MoveOut.State.allCases {
            let row = MoveShow.row(r, move: move(state, started: t0), name: "Work", copied: nil, reach: .open, held: nil, now: t0 + 5)
            XCTAssertEqual(row?.cancels, [.copying, .copied, .waiting].contains(state), "\(state)")
        }
        XCTAssertEqual(MoveShow.row(r, move: move(.cancelling, started: t0), name: "Work", copied: nil, reach: .open, held: nil, now: t0)?.text,
                       "Cancelling the move…")
        XCTAssertEqual(MoveShow.row(r, move: move(.removing, started: t0), name: "Work", copied: nil, reach: .open, held: nil, now: t0)?.text,
                       "Moving to Work…")
    }

    /// A mark with no ledger: a start that a stop cut short goes on, a call for a profile that is gone or that refused waits.
    func testAMarkWithNoLedger() {
        XCTAssertEqual(MoveShow.row(record(moveTo: work), move: nil, name: "Work", copied: nil, reach: .open, held: nil, now: t0),
                       MoveShow.Row(text: "Moving to Work…", cancels: false, held: false))
        XCTAssertEqual(MoveShow.row(record(.recorded, moveTo: "9f9f9f9f"), move: nil, name: nil, copied: nil, reach: .open, held: nil, now: t0),
                       MoveShow.Row(text: MoveWords.heldForGone, cancels: false, held: true))
        let refused = MoveWords.refusal(.refusedIDTaken, target: "Work")!
        XCTAssertEqual(MoveShow.row(record(.recorded, moveTo: work), move: nil, name: "Work", copied: nil, reach: .open, held: refused, now: t0),
                       MoveShow.Row(text: "“Work” cannot take this meeting in. Mossad does not process it until you choose.", cancels: false, held: true))
    }

    func testTheRowNamesNothingOfTheOtherProfileButItsName() {
        let r = record(moveTo: work)
        for reach in [MoveShow.Reach.open, .notSetUp, .unreachable, .notRunning] {
            let text = MoveShow.row(r, move: move(.waiting, started: t0), name: "Work", copied: nil, reach: reach, held: nil, now: t0 + 600)!.text
            XCTAssertFalse(text.contains("/"), text)
            XCTAssertFalse(text.contains(work), text)
        }
    }

    // MARK: The line above the list

    func testTheLineShowsForItsTime() {
        let moved = MoveShow.Line.moved(to: "Work", at: t0)
        XCTAssertEqual(moved.text, "Moved to Work")
        XCTAssertTrue(moved.shows(at: t0 + 7))
        XCTAssertFalse(moved.shows(at: t0 + 8))
        let refusal = MoveShow.Line.refusal("“Work” could not read this meeting. The meeting stays here.", at: t0)
        XCTAssertTrue(refusal.shows(at: t0 + 29))
        XCTAssertFalse(refusal.shows(at: t0 + 30))
    }

    func testTheAnswersToCancel() {
        XCTAssertEqual(MoveShow.Line.cancel(.cancelled, target: "Work", at: t0).text, "The move is cancelled. The meeting stays here.")
        XCTAssertEqual(MoveShow.Line.cancel(.tooLate, target: "Work", at: t0).text, "“Work” has the meeting already.")
        XCTAssertEqual(MoveShow.Line.cancel(.unreachable, target: "Work", at: t0).text, MoveWords.unreachable)
        // The owner's own Cancel is a result; the other two are refusals and stay longer.
        XCTAssertFalse(MoveShow.Line.cancel(.cancelled, target: "Work", at: t0).shows(at: t0 + 8))
        XCTAssertTrue(MoveShow.Line.cancel(.tooLate, target: "Work", at: t0).shows(at: t0 + 20))
    }

    /// A command that would change a meeting while its move waits is refused with one sentence.
    func testACommandOnAMarkedMeeting() {
        XCTAssertNil(MoveShow.refusesCommand(record(), name: nil))
        XCTAssertEqual(MoveShow.refusesCommand(record(moveTo: work), name: "Work"), "This meeting is moving to Work. Wait, or cancel the move.")
        XCTAssertEqual(MoveShow.refusesCommand(record(.recorded, moveTo: "9f9f9f9f"), name: nil), MoveWords.heldForGone)
    }

    // MARK: The menu

    func testTheMenu() {
        let targets = MoveRules.targets(twoProfiles(), active: Profile.defaultID)
        XCTAssertEqual(MoveShow.menu(.offer, record: record(), targets: targets, held: false), .targets(targets.map(\.id)))
        XCTAssertEqual(MoveShow.menu(.moving(to: work), record: record(moveTo: work), targets: targets, held: false), .cancel)
        XCTAssertEqual(MoveShow.menu(.refused(MoveWords.inWork), record: record(.transcribed), targets: targets, held: false), .refused(MoveWords.inWork))
        XCTAssertEqual(MoveShow.menu(.hidden, record: record(.recording), targets: targets, held: false), .none)
        // A held call: "Move to" every target, and "Process here".
        XCTAssertEqual(MoveShow.menu(.moving(to: "9f9f9f9f"), record: record(.recorded, moveTo: "9f9f9f9f"), targets: targets, held: true),
                       .held(targets.map(\.id)))
        // No target: nothing at all, whatever the offer.
        XCTAssertEqual(MoveShow.menu(.offer, record: record(), targets: [], held: false), .none)
        // A held call keeps "Process here" when no other profile is left.
        XCTAssertEqual(MoveShow.menu(.moving(to: "9f9f9f9f"), record: record(.recorded, moveTo: "9f9f9f9f"), targets: [], held: true), .held([]))
    }

    /// A removal that waits after the other profile took the meeting: where, why, and "Try again".
    func testARemovalThatWaitsSaysSoAndOffersTryAgain() {
        var m = move(.removing, started: t0)
        m.because = .backupNotDone
        m.waitsAt = MoveOut.Step.backup.rawValue
        let row = MoveShow.row(record(moveTo: work), move: m, name: "Work", copied: nil, reach: .open, held: nil, now: t0)
        XCTAssertEqual(row, MoveShow.Row(text: "Moved to Work. Mossad still removes it here, and waits to delete its backup copy.",
                                         cancels: false, held: false, retries: true))
    }

    /// In the target, a meeting marked with its own id is arriving: the row says so and names nothing of the first profile.
    func testAMeetingThatArrives() {
        let row = MoveShow.row(record(moveTo: work), move: nil, name: nil, copied: nil, reach: .open, held: nil, now: t0, me: work)
        XCTAssertEqual(row, MoveShow.Row(text: "Arriving from another profile…", cancels: false, held: false))
        XCTAssertTrue(MoveShow.arriving(record(moveTo: work), me: work))
        XCTAssertFalse(MoveShow.arriving(record(moveTo: work), me: Profile.defaultID))
        XCTAssertFalse(MoveShow.arriving(record(), me: work))
        XCTAssertEqual(MoveShow.refusesCommand(record(moveTo: work), name: nil, me: work), MoveWords.arriving)
    }
}
