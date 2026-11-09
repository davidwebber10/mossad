import XCTest
@testable import MossadCore

final class RoomRecordingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func started() -> RoomRecording {
        var r = RoomRecording()
        r.start(at: t0)
        return r
    }

    func testTheAppCountsRecordedTimeItselfAndSkipsPauses() {
        var r = started()
        for i in 1...100 { _ = r.tick(isRecording: true, at: t0.addingTimeInterval(Double(i) * 0.1)) }
        XCTAssertEqual(r.elapsed, 10, accuracy: 0.01)
        _ = r.ownerPause()
        _ = r.tick(isRecording: false, at: t0.addingTimeInterval(70))
        _ = r.ownerResume()
        _ = r.resumed(ok: true, newSegment: false)
        _ = r.tick(isRecording: true, at: t0.addingTimeInterval(70.1))
        XCTAssertEqual(r.elapsed, 10.1, accuracy: 0.01, "The 60 paused seconds do not count")
    }

    func testARecorderThatStopsByItselfIsRestartedThenMovedToANewFile() {
        var r = started()
        _ = r.tick(isRecording: true, at: t0.addingTimeInterval(1))
        XCTAssertEqual(r.tick(isRecording: false, at: t0.addingTimeInterval(2)), [], "A moment of grace for the interruption note")
        XCTAssertEqual(r.tick(isRecording: false, at: t0.addingTimeInterval(4.5)), [.resumeRecorder])
        XCTAssertEqual(r.resumed(ok: false, newSegment: false), [.newSegment])
        XCTAssertEqual(r.resumed(ok: true, newSegment: true), [.cancelAlerts])
        XCTAssertEqual(r.phase, .recording)
        XCTAssertEqual(r.segments, 2)
    }

    func testARecorderThatCannotStartAgainTellsTheOwnerWithANotification() {
        var r = started()
        _ = r.tick(isRecording: false, at: t0.addingTimeInterval(1))
        _ = r.tick(isRecording: false, at: t0.addingTimeInterval(4))
        _ = r.resumed(ok: false, newSegment: false)
        XCTAssertEqual(r.resumed(ok: false, newSegment: true), [.cancelAlerts, .notify(.stopped), .tellOwner(.stopped)])
        XCTAssertEqual(r.phase, .paused(.failed), "The screen no longer says Recording")
    }

    func testAMediaServicesResetStartsANewFile() {
        var r = started()
        XCTAssertEqual(r.recorderDied(), [.newSegment])
        _ = r.resumed(ok: true, newSegment: true)
        XCTAssertEqual(r.segments, 2)
    }

    func testAResetDuringAPauseMakesTheResumeUseANewFile() {
        var r = started()
        _ = r.ownerPause()
        XCTAssertEqual(r.recorderDied(), [])
        XCTAssertEqual(r.ownerResume(), [.newSegment])
    }

    func testAnInterruptionPausesAndSchedulesANotification() {
        var r = started()
        XCTAssertEqual(r.interruption(began: true, shouldResume: false),
                       [.pauseRecorder, .schedule(.paused, after: RoomRecording.pauseAlertDelay)])
        XCTAssertEqual(r.phase, .paused(.interruption))
        XCTAssertEqual(r.interruption(began: false, shouldResume: true), [.resumeRecorder])
        XCTAssertEqual(r.resumed(ok: true, newSegment: false), [.cancelAlerts])
        XCTAssertEqual(r.phase, .recording)
    }

    func testAnInterruptionThatMayNotResumeNotifiesAtOnce() {
        var r = started()
        _ = r.interruption(began: true, shouldResume: false)
        XCTAssertEqual(r.interruption(began: false, shouldResume: false), [.cancelAlerts, .notify(.paused), .tellOwner(.paused)])
    }

    func testAnAutomaticResumeThatFailsNotifies() {
        var r = started()
        _ = r.interruption(began: true, shouldResume: false)
        _ = r.interruption(began: false, shouldResume: true)
        XCTAssertEqual(r.resumed(ok: false, newSegment: false), [.newSegment])
        XCTAssertEqual(r.resumed(ok: false, newSegment: true), [.cancelAlerts, .notify(.paused), .tellOwner(.paused)])
        XCTAssertEqual(r.phase, .paused(.interruption))
    }

    func testAResumeTheOwnerAskedForOnlyShowsItsFailureOnScreen() {
        var r = started()
        _ = r.ownerPause()
        _ = r.ownerResume()
        _ = r.resumed(ok: false, newSegment: false)
        XCTAssertEqual(r.resumed(ok: false, newSegment: true), [.tellOwner(.paused)])
    }

    func testTheOwnersPauseIsNotResumedByTheEndOfAnInterruption() {
        var r = started()
        _ = r.ownerPause()
        XCTAssertEqual(r.interruption(began: true, shouldResume: false), [])
        XCTAssertEqual(r.interruption(began: false, shouldResume: true), [])
        XCTAssertEqual(r.phase, .paused(.owner))
    }

    func testTicksWhilePausedDoNothing() {
        var r = started()
        _ = r.ownerPause()
        XCTAssertEqual(r.tick(isRecording: false, at: t0.addingTimeInterval(30)), [])
    }

    func testARecorderThatReadsZeroNeverDeletesALongRecording() {
        XCTAssertTrue(RoomRecording.keep(measured: 2700, counted: 0, discard: false))
        XCTAssertTrue(RoomRecording.keep(measured: nil, counted: 2700, discard: false), "A file that cannot be measured is kept")
        XCTAssertTrue(RoomRecording.keep(measured: 0, counted: 2700, discard: true), "Discard is for a short recording only")
    }

    func testShortRecordingsAndDiscardsUnderTheLimitAreDropped() {
        XCTAssertFalse(RoomRecording.keep(measured: 30, counted: 31, discard: false))
        XCTAssertFalse(RoomRecording.keep(measured: nil, counted: 20, discard: false))
        XCTAssertFalse(RoomRecording.keep(measured: 75, counted: 74, discard: true), "The owner waited at the dialog a little")
        XCTAssertTrue(RoomRecording.keep(measured: 75, counted: 74, discard: false))
    }
}
