import XCTest
@testable import MossadCore

final class ProcessingQueueTests: XCTestCase {
    var paths: Paths!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    @discardableResult
    func record(_ id: String, _ status: CallStatus, start: Date) throws -> CallRecord {
        let r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: start, end: start.addingTimeInterval(600), status: status)
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try r.save(to: dir)
        return r
    }

    func testRecordRoundTrip() throws {
        var r = try record("a", .recorded, start: t0)
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 1.5, end: 3, text: "Hello")]
        r.speakerNames = ["them:A": "Alex Rivera"]
        r.attendees = ["josh@example.com"]
        try r.save(to: paths.callDirectory("a"))
        let loaded = try CallRecord.load(from: paths.callDirectory("a"))
        XCTAssertEqual(loaded, r)
    }

    func testResumesUnfinishedRecords() throws {
        try record("c", .summarized, start: t0.addingTimeInterval(100))
        try record("b", .recorded, start: t0)
        try record("d", .written, start: t0.addingTimeInterval(200))
        try record("e", .recording, start: t0.addingTimeInterval(300))
        let queue = ProcessingQueue(paths: paths)
        XCTAssertEqual(queue.pending(now: t0.addingTimeInterval(10_000)).map(\.id), ["b", "c"])
    }

    func testBackoffSchedule() {
        let queue = ProcessingQueue(paths: paths)
        var r = CallRecord(id: "x", platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0, status: .recorded)
        var delays: [TimeInterval] = []
        for _ in 1...6 {
            queue.markFailure(&r, now: t0)
            delays.append(r.nextAttempt!.timeIntervalSince(t0))
        }
        XCTAssertEqual(r.attempts, 6)
        XCTAssertEqual(delays, [60, 300, 1800, 7200, 21600, 21600])
    }

    func testNotDueYetIsSkipped() throws {
        var r = try record("f", .recorded, start: t0)
        r.nextAttempt = t0.addingTimeInterval(1000)
        try r.save(to: paths.callDirectory("f"))
        let queue = ProcessingQueue(paths: paths)
        XCTAssertTrue(queue.pending(now: t0.addingTimeInterval(999)).isEmpty)
        XCTAssertEqual(queue.pending(now: t0.addingTimeInterval(1000)).map(\.id), ["f"])
    }

    func testRecoverInterruptedRecording() throws {
        try record("long", .recording, start: t0)
        try writeTestAudio(paths.callDirectory("long").appendingPathComponent("me.caf"), seconds: 90)
        try record("short", .recording, start: t0)
        try writeTestAudio(paths.callDirectory("short").appendingPathComponent("me.caf"), seconds: 30)
        ProcessingQueue(paths: paths).recoverInterrupted()
        let recovered = try CallRecord.load(from: paths.callDirectory("long"))
        XCTAssertEqual(recovered.status, .recorded)
        XCTAssertEqual(recovered.end.timeIntervalSince(t0), 90, accuracy: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory("short").path))
    }

    func testRecoverKeepsCallWhenATrackCannotBeRead() throws {
        try record("bad", .recording, start: t0)
        try Data(repeating: 7, count: 4096).write(to: paths.callDirectory("bad").appendingPathComponent("them.caf"))
        try writeTestAudio(paths.callDirectory("bad").appendingPathComponent("me.caf"), seconds: 5)
        ProcessingQueue(paths: paths).recoverInterrupted()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory("bad").appendingPathComponent("them.caf").path))
    }

    func testRecoverKeepsCallWhenOnlyMicTrackIsShort() throws {
        try record("micfail", .recording, start: t0)
        try writeTestAudio(paths.callDirectory("micfail").appendingPathComponent("me.caf"), seconds: 0.1)
        try writeTestAudio(paths.callDirectory("micfail").appendingPathComponent("them.caf"), seconds: 120)
        ProcessingQueue(paths: paths).recoverInterrupted()
        let r = try CallRecord.load(from: paths.callDirectory("micfail"))
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.end.timeIntervalSince(t0), 120, accuracy: 0.1)
    }
}
