import XCTest
@testable import MossadCore

final class UnconfirmedCallWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    let chrome = UnconfirmedCall(bundleID: "com.google.Chrome", platform: nil, reason: .cannotSeeMeeting)

    func testWarnsOnceAfterTheMicStaysOnForTenSeconds() {
        var watch = UnconfirmedCallWatch()
        XCTAssertNil(watch.update(at: t0, suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(8), suspects: [chrome], inCall: false))
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: false), chrome)
        // The same mic session never warns twice, also after "Not a call".
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(12), suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(300), suspects: [chrome], inCall: false))
    }

    func testABriefMicUseDoesNotWarn() {
        var watch = UnconfirmedCallWatch()
        XCTAssertNil(watch.update(at: t0, suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(4), suspects: [], inCall: false))
        // A new session after a long quiet gap starts the count again.
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(100), suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(105), suspects: [chrome], inCall: false))
    }

    func testANewMicSessionLaterWarnsAgain() {
        var watch = UnconfirmedCallWatch()
        _ = watch.update(at: t0, suspects: [chrome], inCall: false)
        XCTAssertNotNil(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(200), suspects: [chrome], inCall: false))
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(210), suspects: [chrome], inCall: false), chrome)
    }

    func testNoWarningDuringACall() {
        var watch = UnconfirmedCallWatch()
        _ = watch.update(at: t0, suspects: [chrome], inCall: false)
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: true))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(12), suspects: [chrome], inCall: false))
    }
}
