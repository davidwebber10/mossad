import XCTest
@testable import MossadCore

final class InstanceLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func held(_ root: URL) -> InstanceLock? {
        if case .held(let lock) = InstanceLock.acquire(root: root) { return lock }
        return nil
    }

    func testTheFirstCopyGetsTheLock() {
        XCTAssertNotNil(held(dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".lock").path))
    }

    func testASecondCopyIsToldThatTheLockIsTaken() {
        let first = held(dir)
        XCTAssertNotNil(first)
        guard case .taken = InstanceLock.acquire(root: dir) else { return XCTFail("expected taken") }
        withExtendedLifetime(first) {}
    }

    func testTheLockIsFreeAgainWhenItsHolderEnds() {
        var first = held(dir)
        XCTAssertNotNil(first)
        first = nil
        XCTAssertNotNil(held(dir))
    }

    func testAnotherFolderHasItsOwnLock() throws {
        let other = dir.appendingPathComponent("Rehearsal")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let first = held(dir)
        XCTAssertNotNil(held(other))
        withExtendedLifetime(first) {}
    }

    func testAFolderThatCannotBeLockedIsNotAnotherCopy() {
        let missing = dir.appendingPathComponent("missing")
        guard case .failed(let code) = InstanceLock.acquire(root: missing) else { return XCTFail("expected failed") }
        XCTAssertEqual(code, ENOENT)
    }
}
