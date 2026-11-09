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

    func testTheFirstCopyGetsTheLock() {
        XCTAssertNotNil(InstanceLock(root: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".lock").path))
    }

    func testASecondCopyDoesNotGetTheLockWhileTheFirstHoldsIt() {
        let first = InstanceLock(root: dir)
        XCTAssertNotNil(first)
        XCTAssertNil(InstanceLock(root: dir))
        withExtendedLifetime(first) {}
    }

    func testTheLockIsFreeAgainWhenItsHolderEnds() {
        var first = InstanceLock(root: dir)
        XCTAssertNotNil(first)
        first = nil
        XCTAssertNotNil(InstanceLock(root: dir))
    }

    func testAnotherFolderHasItsOwnLock() throws {
        let other = dir.appendingPathComponent("Rehearsal")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let first = InstanceLock(root: dir)
        XCTAssertNotNil(InstanceLock(root: other))
        withExtendedLifetime(first) {}
    }
}
