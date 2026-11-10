import XCTest
@testable import MossadCore

/// The owner changed or disconnected the server during a move: the run must stop, or it copies to the old server,
/// deletes the bucket copies, and removes the bucket settings while the Mac is on another server.
final class ArchiveMoveServerTests: XCTestCase {
    func may(_ serverID: String, run: String?) -> Bool {
        CloudArchive.moveMayGoOn(pending: true, choiceIsServer: true, canMove: true, recording: false, serverID: serverID, runServerID: run)
    }

    func testAMoveGoesOnOnlyOnTheServerItStartedWith() {
        XCTAssertTrue(may("srv-a", run: "srv-a"))
        XCTAssertTrue(may("srv-a", run: nil), "before a run starts, the connected server counts")
        XCTAssertFalse(may("srv-b", run: "srv-a"), "Change server")
        XCTAssertFalse(may("", run: "srv-a"), "Disconnect")
        XCTAssertFalse(may("", run: nil))
    }

    func testTheOtherConditionsStillHold() {
        XCTAssertFalse(CloudArchive.moveMayGoOn(pending: false, choiceIsServer: true, canMove: true, recording: false, serverID: "a", runServerID: "a"))
        XCTAssertFalse(CloudArchive.moveMayGoOn(pending: true, choiceIsServer: false, canMove: true, recording: false, serverID: "a", runServerID: "a"))
        XCTAssertFalse(CloudArchive.moveMayGoOn(pending: true, choiceIsServer: true, canMove: false, recording: false, serverID: "a", runServerID: "a"))
        XCTAssertFalse(CloudArchive.moveMayGoOn(pending: true, choiceIsServer: true, canMove: true, recording: true, serverID: "a", runServerID: "a"))
    }
}
