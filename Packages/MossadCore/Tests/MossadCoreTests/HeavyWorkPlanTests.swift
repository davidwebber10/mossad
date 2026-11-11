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
