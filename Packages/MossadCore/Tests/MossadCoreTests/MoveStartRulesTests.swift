import XCTest
@testable import MossadCore

/// Review g5 F2 and F3: "Process here" never undoes a move that started, and a refused start after the call never loops.
final class MoveStartRulesTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger(_ state: MoveOut.State) -> MoveOut {
        var out = MoveOut(callID: id, to: work, started: t0, afterCall: true)
        out.state = state
        return out
    }

    func testProcessHereOnlyWithNoMoveOrAnEndedOne() {
        XCTAssertTrue(MoveRules.mayProcessHere(ledger: nil, hasFile: false))
        XCTAssertTrue(MoveRules.mayProcessHere(ledger: ledger(.done), hasFile: true))
        for state in [MoveOut.State.copying, .copied, .waiting, .removing, .cancelling] {
            XCTAssertFalse(MoveRules.mayProcessHere(ledger: ledger(state), hasFile: true), "\(state)")
        }
        // A ledger that is there and does not read: not known, so not here.
        XCTAssertFalse(MoveRules.mayProcessHere(ledger: nil, hasFile: true))
    }

    /// A call whose move started shows the move, never "has not started" with "Process here".
    func testAStartedMoveNeverShowsNotStarted() {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 60, status: .recorded)
        r.moveTo = work
        for state in [MoveOut.State.copying, .copied, .waiting] {
            let row = MoveShow.row(r, move: ledger(state), name: "Personal", copied: nil, reach: .open, held: nil, now: t0 + 1)
            XCTAssertEqual(row?.held, false, "\(state)")
            XCTAssertFalse(row?.text.contains("has not started") ?? true, "\(state)")
        }
    }

    func testOnlyAStartLooksAgain() {
        XCTAssertTrue(MoveAfterCall.looksAgain(after: .started))
        XCTAssertFalse(MoveAfterCall.looksAgain(after: .refused("")))
        XCTAssertFalse(MoveAfterCall.looksAgain(after: .refused(MoveWords.inWork)))
    }

    /// A refused start holds the call: the next look does not start it again.
    func testARefusedStartIsHeld() {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 60, status: .recorded)
        r.moveTo = work
        XCTAssertEqual(MoveAfterCall.startsAtLook([r], moving: [], held: [], recording: nil, targets: [work]).map(\.callID), [id])
        XCTAssertEqual(MoveAfterCall.startsAtLook([r], moving: [], held: [id], recording: nil, targets: [work]).map(\.callID), [])
    }
}

/// Review g5 e and n8: `current_call` says why the call that records now has nothing to give.
final class MoveCurrentCallWordsTests: XCTestCase {
    func testTheWordsOfCurrentCall() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveCurrentCallWordsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let paths = Paths(root: url)
        var r = CallRecord(id: "20261101-100000", platform: .zoom, bundleID: "us.zoom.xos", start: Date(), end: Date(), status: .recording)
        r.moveTo = "1a2b3c4d"
        let guessed = ChatTools(records: [r], owner: "Avery Webb", paths: paths, settings: ToolSettings(), liveOff: .maybeOtherProfile)
        XCTAssertEqual(guessed.currentCall(minutes: nil), LiveOffReason.maybeOtherProfile.text)
        let other = ChatTools(records: [r], owner: "Avery Webb", paths: paths, settings: ToolSettings())
        XCTAssertEqual(other.currentCall(minutes: nil), LiveOffReason.forOtherProfile.text)
        r.moveTo = nil
        let back = ChatTools(records: [r], owner: "Avery Webb", paths: paths, settings: ToolSettings(), liveOff: .afterOtherProfile)
        XCTAssertTrue(back.currentCall(minutes: nil).contains(LiveOffReason.afterOtherProfile.text))
        let plain = ChatTools(records: [r], owner: "Avery Webb", paths: paths, settings: ToolSettings())
        XCTAssertTrue(plain.currentCall(minutes: nil).contains("It needs Live transcript on in Settings"))
    }
}
