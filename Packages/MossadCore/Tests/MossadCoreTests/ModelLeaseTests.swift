import XCTest
@testable import MossadCore

final class ModelLeaseTests: XCTestCase {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    func lease(idle: Duration, _ counter: Counter) -> ModelLease {
        let lease = ModelLease("test model", idle: idle, watchesMemory: false)
        lease.onRelease { counter.add() }
        return lease
    }

    /// A model stayed in memory from its first use until the app quit.
    func testAModelIsReleasedWhenNothingUsedItForTheIdleTime() async throws {
        let released = Counter()
        let l = lease(idle: .milliseconds(100), released)
        l.begin()
        l.end()
        XCTAssertEqual(released.count, 0)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(released.count, 1)
    }

    func testAModelInUseIsNotReleased() async throws {
        let released = Counter()
        let l = lease(idle: .milliseconds(100), released)
        l.begin()
        l.end()
        l.begin()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(released.count, 0, "a long transcription keeps its model")
        XCTAssertFalse(l.isFree)
        l.end()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(released.count, 1)
    }

    func testANewUseStartsTheIdleTimeAgain() async throws {
        let released = Counter()
        let l = lease(idle: .milliseconds(300), released)
        for _ in 0..<4 {
            l.begin()
            l.end()
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertEqual(released.count, 0)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(released.count, 1, "one release, not one for each use")
    }

    /// Some hundred uses in a call must end with one release, also when uses overlap.
    func testManyUsesLeaveOneRelease() async throws {
        let released = Counter()
        let l = lease(idle: .milliseconds(150), released)
        for _ in 0..<200 {
            l.begin()
            l.begin()
            l.end()
            l.end()
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(released.count, 1)
    }

    func testMemoryPressureReleasesAFreeModelAtOnce() async throws {
        let released = Counter()
        let l = lease(idle: .seconds(600), released)
        l.begin()
        l.end()
        l.memoryPressure()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(released.count, 1)
    }

    func testMemoryPressureDuringAUseReleasesWhenTheUseEnds() async throws {
        let released = Counter()
        let l = lease(idle: .seconds(600), released)
        l.begin()
        l.memoryPressure()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(released.count, 0)
        l.end()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(released.count, 1)
    }

    func testTheWatcherReachesItsLeases() async throws {
        let released = Counter()
        let l = ModelLease("test model", idle: .seconds(600))
        l.onRelease { released.add() }
        MemoryPressure.shared.fire()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(released.count, 1)
    }
}
