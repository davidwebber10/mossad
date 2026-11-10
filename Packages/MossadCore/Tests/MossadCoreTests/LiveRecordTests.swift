import XCTest
@testable import MossadCore

final class LiveRecordTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ status: CallStatus) -> CallRecord {
        CallRecord(id: "20270115-091500", platform: .inPerson, bundleID: "", start: start, end: start, status: status)
    }

    /// Only the call that records now is live: a record that still says "recording" for another reason is not, and
    /// its menu must not offer to skip the call that records now.
    func testOnlyTheCallRecordingNowIsLive() {
        XCTAssertTrue(record(.recording).isLive(recordingSince: start.addingTimeInterval(0.6)))
        XCTAssertFalse(record(.recording).isLive(recordingSince: nil))
        XCTAssertFalse(record(.recording).isLive(recordingSince: start.addingTimeInterval(600)))
        XCTAssertFalse(record(.written).isLive(recordingSince: start))
    }
}
