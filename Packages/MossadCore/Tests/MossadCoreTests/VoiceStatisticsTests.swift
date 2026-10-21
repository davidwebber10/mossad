import XCTest
@testable import MossadCore

final class VoiceStatisticsTests: XCTestCase {
    func call(_ id: String, _ start: TimeInterval, _ names: [String: String]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: start),
                           end: Date(timeIntervalSince1970: start + 60), status: .written)
        r.speakerNames = names
        return r
    }

    func testCountsMeetingsAndNewestStartPerName() {
        let stats = VoiceStatistics.compute([
            call("1", 100, ["me:A": "David Webber", "them:A": "Alex Rivera"]),
            call("2", 300, ["me:A": "David Webber"]),
            // Two keys with one name in a call still count as one meeting.
            call("3", 200, ["me:A": "David Webber", "them:A": "Alex Rivera", "them:B": "Alex Rivera"]),
            call("4", 400, [:]),
        ])
        XCTAssertEqual(stats, [
            "David Webber": VoiceStats(meetings: 3, lastHeard: Date(timeIntervalSince1970: 300)),
            "Alex Rivera": VoiceStats(meetings: 2, lastHeard: Date(timeIntervalSince1970: 200)),
        ])
    }

    func testNoRecordsGiveNoStats() {
        XCTAssertEqual(VoiceStatistics.compute([]), [:])
    }
}
