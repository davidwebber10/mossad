import XCTest
@testable import MossadCore

final class RoomInterruptionTests: XCTestCase {
    func testAnInterruptionPausesALiveRecording() {
        XCTAssertEqual(RoomInterruption.action(began: true, shouldResume: false, recording: true, pausedByInterruption: false), .pause)
        XCTAssertEqual(RoomInterruption.action(began: true, shouldResume: false, recording: false, pausedByInterruption: false), .none)
    }

    func testTheEndResumesOnlyWhatTheInterruptionPausedAndOnlyWhenTheSystemSaysSo() {
        XCTAssertEqual(RoomInterruption.action(began: false, shouldResume: true, recording: false, pausedByInterruption: true), .resume)
        XCTAssertEqual(RoomInterruption.action(began: false, shouldResume: false, recording: false, pausedByInterruption: true), .tellOwner)
        XCTAssertEqual(RoomInterruption.action(began: false, shouldResume: true, recording: false, pausedByInterruption: false), .none,
                       "The owner's own pause stays paused")
        XCTAssertEqual(RoomInterruption.action(began: false, shouldResume: true, recording: true, pausedByInterruption: false), .none)
    }
}
