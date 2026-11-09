import XCTest
@testable import MossadCore

final class VersionedCacheTests: XCTestCase {
    func testReadsOnceForEachVersion() {
        let cache = VersionedCache<String, Int>()
        var reads = 0
        let load = { () -> Int in reads += 1; return reads }
        XCTAssertEqual(cache.value("a", version: 0, load: load), 1)
        XCTAssertEqual(cache.value("a", version: 0, load: load), 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(cache.value("a", version: 1, load: load), 2)
        XCTAssertEqual(reads, 2)
    }

    func testKeepsEachKeyApart() {
        let cache = VersionedCache<String, String>()
        XCTAssertEqual(cache.value("a", version: 0) { "A" }, "A")
        XCTAssertEqual(cache.value("b", version: 0) { "B" }, "B")
        XCTAssertEqual(cache.value("a", version: 0) { "changed" }, "A")
    }

    func testRemembersAMissingValue() {
        let cache = VersionedCache<String, Int?>()
        var reads = 0
        _ = cache.value("a", version: 0) { reads += 1; return nil }
        _ = cache.value("a", version: 0) { reads += 1; return nil }
        XCTAssertEqual(reads, 1)
    }

    func testForgetReadsAgain() {
        let cache = VersionedCache<String, Int>()
        XCTAssertEqual(cache.value("a", version: 0) { 1 }, 1)
        cache.forget()
        XCTAssertEqual(cache.value("a", version: 0) { 2 }, 2)
    }
}
