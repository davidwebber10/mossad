import XCTest
@testable import MossadCore

final class HeavyWorkPlanTests: XCTestCase {
    func testWithNoCallEveryStepRunsAtTheUsualPriority() {
        for step in HeavyStep.allCases {
            for released in [false, true] {
                let plan = HeavyWorkPlan.plan(for: step, callRecording: false, released: released)
                XCTAssertEqual(plan, .run, "\(step)")
                XCTAssertEqual(plan.priority, .utility)
                XCTAssertFalse(plan.duringCall)
            }
        }
    }

    func testTheJoinAndTheVoicesRunDuringACallAtTheLowestPriority() {
        for step in [HeavyStep.trackJoin, .voiceIdentification] {
            let plan = HeavyWorkPlan.plan(for: step, callRecording: true, released: false)
            XCTAssertEqual(plan, .behindCall, "\(step)")
            XCTAssertEqual(plan.priority, .background)
            XCTAssertTrue(plan.duringCall)
        }
    }

    func testEncodesAndAModelOnThisMacWaitForTheCallToEnd() {
        for step in [HeavyStep.uploadEncode, .recordingEncode, .onDeviceTranscription] {
            XCTAssertEqual(HeavyWorkPlan.plan(for: step, callRecording: true, released: false), .wait, "\(step)")
        }
    }

    func testProcessNowLetsEveryStepOfThatCallRunBehindTheCall() {
        for step in HeavyStep.allCases {
            XCTAssertEqual(HeavyWorkPlan.plan(for: step, callRecording: true, released: true), .behindCall, "\(step)")
        }
    }

    func testTheLogLineNamesTheStepTheCallAndTheTime() {
        XCTAssertEqual(HeavyStep.trackJoin.logLine(callID: "20261020-143000", seconds: 1.234),
                       "During a call: joining the two tracks of 20261020-143000 took 1.2 s")
        XCTAssertEqual(HeavyStep.recordingEncode.logLine(callID: "x", seconds: 12),
                       "During a call: the recording encode of x took 12.0 s")
    }

    func testAReleasedCallRunsDuringACallAndAnotherCallStillWaits() async {
        let gate = HeavyWorkGate(pollInterval: .seconds(3600), isCallRecording: { true })
        var plan = await gate.plan(.uploadEncode, callID: "a")
        XCTAssertEqual(plan, .wait)
        gate.release("a")
        plan = await gate.plan(.uploadEncode, callID: "a")
        XCTAssertEqual(plan, .behindCall)
        plan = await gate.plan(.uploadEncode, callID: "b")
        XCTAssertEqual(plan, .wait)
        XCTAssertTrue(gate.isReleased("a"))
        gate.forget("a")
        XCTAssertFalse(gate.isReleased("a"))
    }

    /// One click: the wait ends at once, not at the next check of the call, which can be seconds away.
    func testAWaitEndsSoonAfterTheRelease() async {
        let gate = HeavyWorkGate(pollInterval: .seconds(3600), isCallRecording: { true })
        let waiter = Task { await gate.waitForClearance(.recordingEncode, callID: "a") }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gate.waiting, ["a"])
        let clock = ContinuousClock(), start = clock.now
        gate.release("a")
        let plan = await waiter.value
        XCTAssertEqual(plan, .behindCall)
        XCTAssertLessThan(clock.now - start, .seconds(2))
        XCTAssertEqual(gate.waiting, [])
    }

    func testTheGateTellsWhoWaits() async {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var sets: [Set<String>] = [] }
        let seen = Seen()
        let gate = HeavyWorkGate(pollInterval: .milliseconds(20), isCallRecording: { true })
        gate.onWaitingChange { set in seen.lock.withLock { seen.sets.append(set) } }
        let waiter = Task { await gate.waitForClearance(.uploadEncode, callID: "a") }
        try? await Task.sleep(for: .milliseconds(100))
        gate.release("a")
        _ = await waiter.value
        XCTAssertEqual(seen.lock.withLock { seen.sets }, [["a"], []])
    }

    func testTheWorkRunsAtThePriorityOfThePlan() async throws {
        let priority = try await HeavyWork.run(priority: .background) { Task.currentPriority }
        XCTAssertEqual(priority, .background, "the waiter at a higher priority does not raise it")
    }
}

final class HeavyLaneTests: XCTestCase {
    func testTheFirstJobRunsAndTheOthersQueueInOrder() {
        var lane = LaneQueue()
        XCTAssertTrue(lane.request(1))
        XCTAssertFalse(lane.request(2))
        XCTAssertFalse(lane.request(3))
        XCTAssertEqual(lane.finish(), 2)
        XCTAssertEqual(lane.finish(), 3)
        XCTAssertNil(lane.finish())
        XCTAssertTrue(lane.request(4), "an empty lane runs the next job at once")
    }

    /// Two released calls, each with two tracks: the heavy bodies never overlap while a call records.
    func testTwoReleasedCallsNeverRunTwoHeavyJobsAtOnce() async throws {
        final class Count: @unchecked Sendable {
            let lock = NSLock(); var now = 0; var most = 0; var done = 0
            func enter() { lock.withLock { now += 1; most = max(most, now) } }
            func leave() { lock.withLock { now -= 1; done += 1 } }
        }
        let count = Count()
        let lane = HeavyLane()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await lane.run {
                        count.enter()
                        try? await Task.sleep(for: .milliseconds(30))
                        count.leave()
                    }
                }
            }
        }
        XCTAssertEqual(count.most, 1)
        XCTAssertEqual(count.done, 4)
    }

    func testTheLaneGoesOnAfterAJobThrows() async {
        let lane = HeavyLane()
        let first: Result<Int, Error> = await lane.run { throw Boom() }
        let second: Result<Int, Error> = await lane.run { 7 }
        XCTAssertThrowsError(try first.get())
        XCTAssertEqual(try? second.get(), 7)
    }
}

final class ProcessNowLabelTests: XCTestCase {
    func testTheLabelSaysHowManyCallsTheClickReleases() {
        XCTAssertNil(ProcessNowLabel.title(waiting: 0), "nothing waits: no button")
        XCTAssertEqual(ProcessNowLabel.title(waiting: 1), "Process now")
        XCTAssertEqual(ProcessNowLabel.title(waiting: 2), "Process 2 calls now")
        XCTAssertEqual(ProcessNowLabel.title(waiting: 5), "Process 5 calls now")
    }

    func testTheLineSaysHowManyCallsWait() {
        XCTAssertNil(ProcessNowLabel.line(waiting: 0))
        XCTAssertEqual(ProcessNowLabel.line(waiting: 1), "1 call waits for this one")
        XCTAssertEqual(ProcessNowLabel.line(waiting: 3), "3 calls wait for this one")
    }

    func testAFailedStepSaysSoInItsLogLine() {
        XCTAssertEqual(HeavyStep.uploadEncode.logLine(callID: "x", seconds: 2, failed: true),
                       "During a call: the upload encode of x failed after 2.0 s")
    }
}
