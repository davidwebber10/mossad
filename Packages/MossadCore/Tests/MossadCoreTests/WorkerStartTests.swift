import XCTest
@testable import MossadCore

/// The order of a worker's start: nothing of the profile's folder is read or written before its lock is held.
final class WorkerStartTests: XCTestCase {
    final class Trace {
        var steps: [WorkerStart.Step] = []
    }

    private func steps(_ t: Trace, refusal: String? = nil, front: Bool = true, lock: Bool = true, setup: Bool = true) -> WorkerStart.Steps {
        WorkerStart.Steps(refusal: { t.steps.append(.refuse); return refusal },
                          foreground: { t.steps.append(.foreground); return front },
                          makeRoot: { t.steps.append(.makeRoot) },
                          lock: { t.steps.append(.lock); return lock },
                          prepare: { t.steps.append(.prepare) },
                          proofCall: { t.steps.append(.proofCall) },
                          setupDone: { t.steps.append(.settings); return setup },
                          watch: { t.steps.append(.watch) },
                          run: { t.steps.append(.run) })
    }

    func testTheLockComesBeforeAnythingOfTheFolder() {
        let t = Trace()
        XCTAssertNil(WorkerStart.run(steps(t)))
        XCTAssertEqual(t.steps, [.refuse, .foreground, .makeRoot, .lock, .prepare, .proofCall, .settings, .watch, .run])
        XCTAssertEqual(t.steps, WorkerStart.Step.allCases)
    }

    func testEachStopEndsTheStart() {
        let cases: [(WorkerStart.Steps, Trace, WorkerLaunch.Exit, WorkerStart.Step)] = {
            let a = Trace(), b = Trace(), c = Trace(), d = Trace()
            return [(steps(a, refusal: "no"), a, .refused, .refuse), (steps(b, front: false), b, .noForeground, .foreground),
                    (steps(c, lock: false), c, .lockNotHeld, .lock), (steps(d, setup: false), d, .setupNotDone, .settings)]
        }()
        for (s, t, exit, last) in cases {
            XCTAssertEqual(WorkerStart.run(s)?.exit, exit)
            XCTAssertEqual(t.steps.last, last, "\(t.steps)")
        }
    }
}
