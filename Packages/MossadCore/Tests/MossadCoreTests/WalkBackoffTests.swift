#if os(macOS)
import XCTest
@testable import MossadCore

final class WalkBackoffTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func testTheFirstWalkIsAllowedAtOnce() {
        XCTAssertTrue(WalkBackoff().mayWalk(at: t0))
    }

    /// Walks with no cached read between them wait 3 s, 10 s, 30 s, and then 60 s.
    func testWalksInARowAreSpacedFurtherApart() {
        var b = WalkBackoff()
        var time = t0
        for wait in [3.0, 10, 30, 60, 60] {
            b.walked(at: time)
            XCTAssertFalse(b.mayWalk(at: time.addingTimeInterval(wait - 1)), "too early after \(wait) s step")
            XCTAssertTrue(b.mayWalk(at: time.addingTimeInterval(wait)))
            time = time.addingTimeInterval(wait)
        }
        XCTAssertTrue(b.isOff)
    }

    /// The 1 s check while muted must not walk every second when the cache does not hold.
    func testAOneSecondCheckWalksAtMostEveryThreeSeconds() {
        var b = WalkBackoff()
        var walks = 0
        for second in 0..<10 {
            let time = t0.addingTimeInterval(Double(second))
            if b.mayWalk(at: time) { b.walked(at: time); walks += 1 }
        }
        XCTAssertEqual(walks, 2)  // at 0 s and at 3 s; the next one is due at 13 s
    }

    /// A walk whose controls answer from the cache was worth it: the next walk (the button was replaced) is at once.
    func testACachedReadStartsTheCountAgain() {
        var b = WalkBackoff()
        b.walked(at: t0)
        b.walked(at: t0.addingTimeInterval(3))
        b.cacheHeld()
        XCTAssertTrue(b.mayWalk(at: t0.addingTimeInterval(3.5)))
        XCTAssertFalse(b.isOff)
    }

    /// "Muted" that cannot be read turns into "unmuted" after 10 s, so while muted the walks stay 5 s apart at most.
    func testWhileMutedTheWalksAreNeverMoreThanFiveSecondsApart() {
        var b = WalkBackoff()
        var walks: [Double] = []
        for second in 0..<30 {
            let time = t0.addingTimeInterval(Double(second))
            if b.mayWalk(at: time, whileMuted: true) { b.walked(at: time); walks.append(Double(second)) }
        }
        XCTAssertEqual(walks, [0, 3, 8, 13, 18, 23, 28])
        XCTAssertFalse(b.mayWalk(at: t0.addingTimeInterval(30)), "not muted any more: the long wait applies")
    }

    func testFourWalksInARowTurnDetectionAsGoodAsOff() {
        var b = WalkBackoff()
        for i in 0..<3 { b.walked(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertFalse(b.isOff)
        b.walked(at: t0.addingTimeInterval(50))
        XCTAssertTrue(b.isOff)
        XCTAssertFalse(b.mayWalk(at: t0.addingTimeInterval(109)))
        XCTAssertTrue(b.mayWalk(at: t0.addingTimeInterval(110)))
    }
}
#endif
