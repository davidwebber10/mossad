import XCTest
@testable import MossadCore

final class WorkerStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, _ status: CallStatus, endedHoursAgo: Double = 3, attempts: Int = 0, failedStep: CallStatus? = nil) -> CallRecord {
        let end = now.addingTimeInterval(-endedHoursAgo * 3600)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: end.addingTimeInterval(-1800), end: end, status: status)
        r.attempts = attempts
        r.failedStep = failedStep
        return r
    }

    private var records: [CallRecord] {
        [record("a", .recorded, endedHoursAgo: 2, attempts: 2), record("b", .recorded), record("c", .identified),
         record("d", .written), record("e", .written), record("f", .written),
         record("g", .failed, endedHoursAgo: 24, failedStep: .transcribed), record("h", .failed, endedHoursAgo: 30 * 24, failedStep: .recorded)]
    }

    func testTheStatusCountsMeetingsInWorkAndNamesTheNewestFailure() {
        var s = WorkerStatus.make(records: records, missing: [], backupFailed: 0, syncFailed: false, now: now)
        XCTAssertEqual(s.inWork, 3)
        XCTAssertEqual(s.failure, .init(kind: .transcribe, count: 1))
        var calm = records
        calm[0].attempts = 0
        s = WorkerStatus.make(records: calm, missing: [], backupFailed: 0, syncFailed: false, now: now)
        XCTAssertEqual(s.failure, .init(kind: .identify, count: 1), "from the meeting that failed yesterday; 30 days ago never counts")
        XCTAssertEqual(WorkerStatus.make(records: records, missing: [.transcription], backupFailed: 0, syncFailed: false, now: now).failure, .init(kind: .key, count: 2))
        XCTAssertEqual(WorkerStatus.make(records: records, missing: [.notes], backupFailed: 0, syncFailed: false, now: now).failure, .init(kind: .key, count: 1))
        let quiet = [record("d", .written)]
        XCTAssertEqual(WorkerStatus.make(records: quiet, missing: [], backupFailed: 2, syncFailed: false, now: now).failure, .init(kind: .backup, count: 2))
        XCTAssertEqual(WorkerStatus.make(records: quiet, missing: [], backupFailed: 0, syncFailed: true, now: now).failure, .init(kind: .sync, count: 0))
        XCTAssertNil(WorkerStatus.make(records: quiet, missing: [], backupFailed: 0, syncFailed: false, now: now).failure)
        // Two of the same kind count together.
        let two = [record("a", .recorded, endedHoursAgo: 2, attempts: 1), record("b", .recorded, endedHoursAgo: 5, attempts: 3)]
        XCTAssertEqual(WorkerStatus.make(records: two, missing: [], backupFailed: 0, syncFailed: false, now: now).failure, .init(kind: .transcribe, count: 2))
    }

    func testTheStatusFileHoldsCountsAndAKindOnly() throws {
        var r = record("20261020-143000", .recorded, attempts: 1)
        r.calendarTitle = "Budget review"
        r.speakerNames = ["them:A": "Sam Carter"]
        r.invitees = [Invitee(name: "Sam Carter", email: "sam@example.com")]
        let status = WorkerStatus.make(records: [r], missing: [], backupFailed: 0, syncFailed: false, now: now)
        let data = try JSONEncoder().encode(status)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Budget")); XCTAssertFalse(text.contains("Sam")); XCTAssertFalse(text.contains("@"))
        XCTAssertFalse(text.contains("20261020"))
        func keys(_ value: Any) -> [String] {
            if let d = value as? [String: Any] { return d.keys.map { $0 } + d.values.flatMap(keys) }
            if let a = value as? [Any] { return a.flatMap(keys) }
            return []
        }
        let all = keys(try JSONSerialization.jsonObject(with: data))
        XCTAssertFalse(all.isEmpty)
        for k in all { XCTAssertTrue(WorkerStatus.allowedKeys.contains(k), k) }
    }

    func testTheLineOfEachState() {
        func line(_ inWork: Int, _ f: WorkerStatus.Failure?, running: Bool = true, gaveUp: Bool = false) -> String? {
            WorkerStatusLine.text(WorkerStatus(written: now, inWork: inWork, failure: f), running: running, gaveUp: gaveUp)
        }
        XCTAssertNil(line(0, nil)); XCTAssertEqual(line(1, nil), "1 meeting in work"); XCTAssertEqual(line(2, nil), "2 meetings in work")
        XCTAssertEqual(line(3, .init(kind: .transcribe, count: 1)), "Could not transcribe 1 meeting")
        XCTAssertEqual(line(3, .init(kind: .transcribe, count: 2)), "Could not transcribe 2 meetings")
        XCTAssertEqual(line(3, .init(kind: .key, count: 2)), "2 meetings wait for a key")
        XCTAssertEqual(line(3, .init(kind: .key, count: 1)), "1 meeting waits for a key")
        XCTAssertEqual(line(3, .init(kind: .identify, count: 1)), "Could not name the voices of 1 meeting")
        XCTAssertEqual(line(3, .init(kind: .identify, count: 2)), "Could not name the voices of 2 meetings")
        XCTAssertEqual(line(3, .init(kind: .summarize, count: 1)), "Could not summarize 1 meeting")
        XCTAssertEqual(line(0, .init(kind: .write, count: 1)), "Could not write the note of 1 meeting")
        XCTAssertEqual(line(0, .init(kind: .write, count: 2)), "Could not write the notes of 2 meetings")
        XCTAssertEqual(line(0, .init(kind: .backup, count: 1)), "Could not back up 1 recording")
        XCTAssertEqual(line(0, .init(kind: .backup, count: 2)), "Could not back up 2 recordings")
        XCTAssertEqual(line(0, .init(kind: .sync, count: 0)), "Could not sync")
        XCTAssertNil(line(2, nil, running: false)); XCTAssertEqual(line(2, nil, running: false, gaveUp: true), "Not running")
        XCTAssertNil(WorkerStatusLine.text(nil, running: true, gaveUp: false))
        XCTAssertEqual(WorkerStatusLine.text(nil, running: false, gaveUp: true), "Not running")
    }

    func testTheFileIsReadOnlyWhenThisBuildKnowsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(WorkerStatus.peek(root: root))
        let s = WorkerStatus(written: now, inWork: 2, failure: .init(kind: .key, count: 1))
        try s.save(root: root)
        XCTAssertEqual(WorkerStatus.url(root: root).path, root.appendingPathComponent("Worker/status.json").path)
        XCTAssertEqual(WorkerStatus.peek(root: root), s)
        try Data(#"{"version":2,"written":0,"inWork":1}"#.utf8).write(to: WorkerStatus.url(root: root))
        XCTAssertNil(WorkerStatus.peek(root: root))
        try Data("not json".utf8).write(to: WorkerStatus.url(root: root))
        XCTAssertNil(WorkerStatus.peek(root: root))
        XCTAssertEqual(Paths(root: root).worker.path, root.appendingPathComponent("Worker").path)
    }

    func testOneProfileMakesNoWorkerFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-worker-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Paths(root: root).ensureDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Worker").path))
    }

    func testAStatusFromBeforeTheWorkerStartedIsNotShown() {
        let started = Date(timeIntervalSince1970: 1_900_000_000)
        let old = WorkerStatus(written: started.addingTimeInterval(-86_400), inWork: 2, failure: nil)
        XCTAssertNil(WorkerStatusLine.text(old, running: true, gaveUp: false, since: started), "the new worker is starting")
        let fresh = WorkerStatus(written: started.addingTimeInterval(5), inWork: 2, failure: nil)
        XCTAssertEqual(WorkerStatusLine.text(fresh, running: true, gaveUp: false, since: started), "2 meetings in work")
        XCTAssertEqual(WorkerStatusLine.text(old, running: false, gaveUp: true, since: started), "Not running")
    }
}
