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

extension PipelineTests {
    /// Two meetings of a worker at one time: their heavy steps go one after the other through the gate's lane, and
    /// none of them writes the "during a call" line.
    func testAWorkersHeavyStepsRunOneAtATimeAndWriteNoCallLine() async throws {
        var ids: [String] = []
        for (n, minute) in [(1, 0), (2, 40)] {
            let id = String(format: "20261020-14%02d00", minute)
            let dir = paths.callDirectory(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeSegments(dir.appendingPathComponent("me.caf"), total: 30, [(0, 10, 200)])
            try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(11, 20, Double(400 * n))])
            var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start.addingTimeInterval(Double(minute) * 60),
                               end: start.addingTimeInterval(Double(minute) * 60 + 1800), status: .identified)
            r.utterances = transcriber.result.values.flatMap { $0 }
            r.speakerNames = ["me:A": "Avery Lane"]
            try r.save(to: dir)
            ids.append(id)
        }
        final class Overlap: @unchecked Sendable {
            private let lock = NSLock()
            private var now = 0, top = 0
            func enter() { lock.withLock { now += 1; top = max(top, now) } }
            func leave() { lock.withLock { now -= 1 } }
            var most: Int { lock.withLock { top } }
        }
        let overlap = Overlap()
        let lines = LogLines()
        let gate = HeavyWorkGate(pollInterval: .milliseconds(20), isCallRecording: { false }, worker: true, log: { lines.add($0) })
        let later = start.addingTimeInterval(7200)
        let p = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: ToneEmbeddingProvider(),
                         calendar: FakeCalendar(), summarizer: summarizer, notify: { _ in }, now: { later }, ownerName: "Avery Lane",
                         heavy: gate)
        await p.setRecordingMaker { _ in
            overlap.enter()
            Thread.sleep(forTimeInterval: 0.3)
            overlap.leave()
        }
        async let one: Void = p.process(ids[0])
        async let two: Void = p.process(ids[1])
        _ = await (one, two)
        for id in ids { XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).status, .written) }
        XCTAssertEqual(overlap.most, 1)
        XCTAssertEqual(lines.all, [])
    }
}
