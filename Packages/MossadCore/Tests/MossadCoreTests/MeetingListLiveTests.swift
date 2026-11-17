import XCTest
@testable import MossadCore

/// The Meetings list leaves out only the call that records now (the sidebar's Now card shows it), by its id.
final class MeetingListLiveTests: XCTestCase {
    private func record(_ id: String, _ status: CallStatus) -> CallRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start, status: status)
    }

    /// A record left as "recording" by another copy of the app is not the live call: it stays a row.
    func testOnlyTheLiveCallLeavesTheList() {
        let records = [record("live", .recording), record("stale", .recording), record("done", .written)]
        XCTAssertEqual(MeetingListRows.listed(records, liveID: "live").map(\.id), ["stale", "done"])
        XCTAssertEqual(MeetingListRows.listed(records, liveID: nil).map(\.id), ["live", "stale", "done"])
    }

    /// The first call of a new owner: with nothing else, the live call's page opens.
    func testFirstSelection() {
        XCTAssertEqual(MeetingListRows.firstSelection([record("live", .recording)], liveID: "live"), "live")
        XCTAssertEqual(MeetingListRows.firstSelection([record("live", .recording), record("done", .written)], liveID: "live"), "done")
        XCTAssertEqual(MeetingListRows.firstSelection([record("stale", .recording), record("done", .written)], liveID: nil), "stale")
        XCTAssertNil(MeetingListRows.firstSelection([], liveID: nil))
    }
}
