import Foundation
import MossadObjC
import XCTest
@testable import MossadCore

/// A change of the audio route never crashes the app or ends the mic early: the format check before a tap, the
/// settling retries, and the catcher of Objective-C exceptions.
final class MicRestartTests: XCTestCase {
    func testTheCatcherTurnsAnExceptionIntoAnError() {
        XCTAssertThrowsError(try ObjCException.catching {
            NSException(name: .invalidArgumentException, reason: "required condition is false: format.sampleRate == hwFormat.sampleRate").raise()
        }) { error in
            XCTAssertTrue("\(error)".contains("hwFormat"), "\(error)")
        }
        var ran = false
        XCTAssertNoThrow(try ObjCException.catching { ran = true })
        XCTAssertTrue(ran)
    }

    func testATapGoesOnOnlyWhenTheTwoSidesAgree() {
        let hz48 = MicFormat(sampleRate: 48_000, channels: 1), hz24 = MicFormat(sampleRate: 24_000, channels: 1)
        XCTAssertEqual(MicStartCheck.check(hardware: hz48, output: hz48), .ok)
        // A headset leaving call mode: the hardware is at 48 kHz, the node still says 24 kHz.
        XCTAssertEqual(MicStartCheck.check(hardware: hz48, output: hz24), .settling)
        // Channel counts can differ for good (a 2-channel input, voice processing): only the rate says "settling".
        XCTAssertEqual(MicStartCheck.check(hardware: hz48, output: MicFormat(sampleRate: 48_000, channels: 2)), .ok)
        XCTAssertEqual(MicStartCheck.check(hardware: MicFormat(sampleRate: 48_000, channels: 2), output: MicFormat(sampleRate: 48_000, channels: 5)), .ok)
        XCTAssertEqual(MicStartCheck.check(hardware: hz48, output: MicFormat(sampleRate: 0, channels: 0)), .settling)
        // No input device at all, on both sides: no microphone.
        XCTAssertEqual(MicStartCheck.check(hardware: MicFormat(sampleRate: 0, channels: 0), output: MicFormat(sampleRate: 0, channels: 0)), .noInput)
        XCTAssertEqual(MicStartCheck.check(hardware: MicFormat(sampleRate: 0, channels: 0), output: hz48), .settling)
    }

    func testAFailedRestartIsRetriedWithBackoffThenGivesUp() {
        var plan = MicRestartPlan()
        guard case .restart(let token, let after)? = plan.configurationChanged() else { return XCTFail("no restart") }
        XCTAssertEqual(after, 0)
        XCTAssertTrue(plan.pending)
        var delays: [Double] = []
        var step = plan.failed(token: token)
        while case .restart(let t, let d)? = step {
            delays.append(d)
            step = plan.failed(token: t)
        }
        XCTAssertEqual(delays, [0.3, 0.6, 1.2, 2.4, 4.8])
        XCTAssertLessThanOrEqual(delays.reduce(0, +), 10)
        XCTAssertEqual(step, .giveUp)
        XCTAssertFalse(plan.pending)
    }

    func testChangesDuringTheSettlingJoinThePendingRestart() {
        var plan = MicRestartPlan()
        guard case .restart(let token, _)? = plan.configurationChanged() else { return XCTFail("no restart") }
        // A second and a third notification while it settles: no second restart.
        XCTAssertNil(plan.configurationChanged())
        XCTAssertNil(plan.configurationChanged())
        guard case .restart(let next, _)? = plan.failed(token: token) else { return XCTFail("no retry") }
        XCTAssertNil(plan.configurationChanged())
        plan.succeeded(token: next)
        XCTAssertFalse(plan.pending)
        // After it settled, a new change restarts again from the start of the backoff.
        guard case .restart(let again, let after)? = plan.configurationChanged() else { return XCTFail("no restart") }
        XCTAssertEqual(after, 0)
        XCTAssertNotEqual(again, next)
    }

    func testStopCancelsAPendingRetryAndAnOldTokenDoesNothing() {
        var plan = MicRestartPlan()
        guard case .restart(let token, _)? = plan.configurationChanged() else { return XCTFail("no restart") }
        plan.stop()
        XCTAssertFalse(plan.pending)
        // The retry that was waiting fires after stop: nothing.
        XCTAssertNil(plan.failed(token: token))
        // Nothing restarts after stop.
        XCTAssertNil(plan.configurationChanged())
    }

    // F2: the check never blocks for good.
    func testTheCheckWaitsButNeverBlocksForGood() {
        XCTAssertEqual(MicStartDecision.decide(.ok, lastChance: false), .install)
        XCTAssertEqual(MicStartDecision.decide(.settling, lastChance: false), .wait)
        XCTAssertEqual(MicStartDecision.decide(.settling, lastChance: true), .installAnyway)
        XCTAssertEqual(MicStartDecision.decide(.noInput, lastChance: true), .noInput)
    }

    func testTheLastRestartIsTheLastChance() {
        var plan = MicRestartPlan()
        guard case .restart(var token, _)? = plan.configurationChanged() else { return XCTFail("no restart") }
        var chances: [Bool] = [plan.isLastChance(token)]
        while case .restart(let t, _)? = plan.failed(token: token) {
            token = t
            chances.append(plan.isLastChance(t))
        }
        XCTAssertEqual(chances, [false, false, false, false, false, true])
    }

    func testAFirstStartThatSettlesWaitsOnceThenInstallsAnyway() {
        var plan = MicRestartPlan()
        guard case .restart(let token, let after)? = plan.firstStartSettling() else { return XCTFail("no wait") }
        XCTAssertEqual(after, MicRestartPlan.delays[0])
        XCTAssertTrue(plan.pending)
        XCTAssertTrue(plan.isLastChance(token))
        // The last chance failed too (or sent nothing): the recorder's own retry takes over.
        XCTAssertEqual(plan.failed(token: token), .giveUp)
        // A route change meanwhile joins it.
        var other = MicRestartPlan()
        _ = other.firstStartSettling()
        XCTAssertNil(other.configurationChanged())
    }

    // A started engine that sends nothing is a failed start: the same plan goes on.
    func testASilentEngineIsAFailedStart() {
        var plan = MicRestartPlan()
        guard case .restart(let token, _)? = plan.configurationChanged() else { return XCTFail("no restart") }
        // Started: still pending until the first buffer within the wait.
        XCTAssertTrue(plan.pending)
        XCTAssertEqual(MicRestartPlan.livenessWait, 2)
        guard case .restart(let next, let after)? = plan.failed(token: token) else { return XCTFail("no retry") }
        XCTAssertEqual(after, 0.3)
        plan.succeeded(token: next)
        XCTAssertFalse(plan.pending)
    }

    // F10: an old token does nothing after a newer one succeeded.
    func testAnOldTokenDoesNothingAfterANewerSucceeded() {
        var plan = MicRestartPlan()
        guard case .restart(let first, _)? = plan.configurationChanged(),
              case .restart(let second, _)? = plan.failed(token: first) else { return XCTFail("no retry") }
        plan.succeeded(token: second)
        XCTAssertNil(plan.failed(token: first))
        XCTAssertFalse(plan.isCurrent(first))
        plan.succeeded(token: first)
        XCTAssertFalse(plan.pending)
    }

    // F1: a call that ended by itself too short to keep reopens the ticks of its own id; a kept call reopens none.
    func testTheGoneCallIsTheRecordTheRecorderHeld() {
        let kept = CallRecord(id: "20261113-133030", platform: .meet, bundleID: "", start: Date(), end: Date(), status: .recorded)
        XCTAssertEqual(GoneCall.id(recording: "20261113-133030", kept: nil), "20261113-133030")
        XCTAssertNil(GoneCall.id(recording: "20261113-133030", kept: kept))
        // A stop by hand already ended it: the later end has no record and reopens nothing.
        XCTAssertNil(GoneCall.id(recording: nil, kept: nil))
    }
}
