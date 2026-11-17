import XCTest
@testable import MossadCore

final class WorkerPaceTests: XCTestCase {
    func testTheSyncWaitGrowsToAnHour() {
        XCTAssertEqual([0, 1, 2, 3, 4, 9].map(WorkerPace.syncWait), [300, 600, 1200, 2400, 3600, 3600])
    }

    func testWhatIsDue() {
        var pace = WorkerPace(); let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(pace.due(now: t, callRecords: false).work, [.queue, .sync])
        XCTAssertEqual(pace.due(now: t, callRecords: true).work, [.queue])
        pace.queued(at: t); pace.synced(ok: true, at: t)
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(299), callRecords: false).work, [])
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(299), callRecords: false).sleep, 1)
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(10), callRecords: false).sleep, 290)
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(300), callRecords: false).work, [.sync])
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(300), callRecords: true).sleep, 5)
        pace.synced(ok: false, at: t); pace.synced(ok: false, at: t)
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(1199), callRecords: false).work, [])
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(1200), callRecords: false).work, [.sync])
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(3600), callRecords: false).work, [.queue, .sync])
    }

    func testAPassThatChangedSomethingMakesTheSyncDue() {
        var pace = WorkerPace(); let t = Date(timeIntervalSince1970: 1_000_000)
        pace.queued(at: t); pace.synced(ok: true, at: t)
        pace.changed()
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(1), callRecords: false).work, [.sync])
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(1), callRecords: true).work, [])
        pace.synced(ok: true, at: t.addingTimeInterval(1))
        XCTAssertEqual(pace.due(now: t.addingTimeInterval(2), callRecords: false).work, [])
    }
}
