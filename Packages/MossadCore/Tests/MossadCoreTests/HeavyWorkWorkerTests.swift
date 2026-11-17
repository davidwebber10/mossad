import Synchronization
import XCTest
@testable import MossadCore

/// A worker's heavy steps: one at a time behind the app in front, and held for a call as the app's own are.
final class HeavyWorkWorkerTests: XCTestCase {
    func testAWorkerRunsEachHeavyStepBehindTheAppWhenNoCallRecords() {
        for step in HeavyStep.allCases {
            let plan = HeavyWorkPlan.plan(for: step, callRecording: false, released: false, worker: true)
            XCTAssertEqual(plan, .behindApp, "\(step)")
            XCTAssertEqual(plan.priority, .background)
            XCTAssertTrue(plan.usesLane)
            XCTAssertFalse(plan.duringCall)
        }
    }

    func testAWorkerFollowsTheForegroundsCallAsItsOwn() {
        for step in HeavyStep.allCases {
            for released in [false, true] {
                XCTAssertEqual(HeavyWorkPlan.plan(for: step, callRecording: true, released: released, worker: true),
                               HeavyWorkPlan.plan(for: step, callRecording: true, released: released), "\(step)")
            }
        }
    }

    func testTheAppsOwnPlansAreAsBefore() {
        XCTAssertEqual(HeavyWorkPlan.plan(for: .uploadEncode, callRecording: false, released: false), .run)
        XCTAssertFalse(HeavyWorkPlan.run.usesLane); XCTAssertFalse(HeavyWorkPlan.wait.usesLane)
        XCTAssertTrue(HeavyWorkPlan.behindCall.usesLane)
        XCTAssertTrue(HeavyWorkPlan.behindCall.duringCall); XCTAssertTrue(HeavyWorkPlan.wait.duringCall)
        XCTAssertFalse(HeavyWorkPlan.run.duringCall)
    }

    func testAWorkersGateHoldsAnEncodeWhileTheFlagIsUp() async {
        let flag = Mutex(true)
        let gate = HeavyWorkGate(pollInterval: .milliseconds(20), isCallRecording: { flag.withLock { $0 } }, worker: true, log: { _ in })
        let encode = await gate.plan(.uploadEncode, callID: "c")
        XCTAssertEqual(encode, .wait)
        let model = await gate.plan(.onDeviceTranscription, callID: "c")
        XCTAssertEqual(model, .wait)
        let voices = await gate.plan(.voiceIdentification, callID: "c")
        XCTAssertEqual(voices, .behindCall)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            flag.withLock { $0 = false }
        }
        let cleared = await gate.waitForClearance(.uploadEncode, callID: "c")
        XCTAssertEqual(cleared, .behindApp)
        // A released call in a worker with no call runs behind the app too, never at the app's own priority.
        gate.release("d")
        let released = await gate.plan(.uploadEncode, callID: "d")
        XCTAssertEqual(released, .behindApp)
    }

    func testTheAppsGateIsAsBefore() async {
        let gate = HeavyWorkGate(isCallRecording: { false }, log: { _ in })
        let plan = await gate.plan(.uploadEncode, callID: "c")
        XCTAssertEqual(plan, .run)
    }
}
