import AVFoundation
import XCTest
@testable import MossadCore

final class OutboxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func rec(_ id: String) -> PhoneRecording { PhoneRecording(id: id, start: t0, end: t0, title: nil) }

    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testAnEntryExistsFromTheStartAndWaitsOnceFinished() {
        var o = Outbox()
        o.begin(rec("a"))
        XCTAssertEqual(o["a"]?.state, .recording)
        XCTAssertEqual(o.due(store: "icloud", now: t0), [], "A recording in progress does not upload")
        o.finish("a", end: t0.addingTimeInterval(600), title: "Planning")
        XCTAssertEqual(o["a"]?.state, .waiting)
        XCTAssertEqual(o["a"]?.recording.end, t0.addingTimeInterval(600))
        XCTAssertEqual(o["a"]?.recording.title, "Planning")
        XCTAssertEqual(o.due(store: "icloud", now: t0).map(\.id), ["a"])
    }

    func testASentRecordingUploadsAgainWhenTheStoreChangedOrNoMeetingCame() {
        var o = Outbox()
        o.begin(rec("a"))
        o.finish("a", end: t0, title: nil)
        o.markSent("a", store: "icloud", at: t0)
        XCTAssertEqual(o.due(store: "icloud", now: t0.addingTimeInterval(3600)), [])
        XCTAssertEqual(o.due(store: "server:https://notes.example.com", now: t0).map(\.id), ["a"])
        XCTAssertEqual(o.due(store: "icloud", now: t0.addingTimeInterval(Outbox.resendAfter)).map(\.id), ["a"])
    }

    func testSendAgainPutsASentRecordingBackInLine() {
        var o = Outbox()
        o.begin(rec("a"))
        o.finish("a", end: t0, title: nil)
        o.markSent("a", store: "icloud", at: t0)
        o.sendAgain("a")
        XCTAssertEqual(o["a"]?.state, .waiting)
    }

    func testOnlyAnArrivedMeetingRemovesAnEntry() {
        var o = Outbox()
        for id in ["a", "b", "c"] { o.begin(rec(id)) }
        o.finish("a", end: t0, title: nil)
        o.markSent("a", store: "icloud", at: t0)
        o.finish("b", end: t0, title: nil)
        XCTAssertEqual(o.settle(arrived: ["a", "b", "c"]), ["a", "b"], "An upload may have worked just before the app stopped")
        XCTAssertEqual(o.entries.map(\.id), ["c"], "A recording in progress stays")
    }

    func testLaunchFindsUnfinishedRecordingsAndAudioWithNoEntry() {
        var o = Outbox()
        o.begin(rec("a"))
        o.begin(rec("b"))
        o.finish("b", end: t0, title: nil)
        o.begin(rec("live"))
        XCTAssertEqual(o.needsRecovery(audioIDs: ["a", "b", "live", "orphan"], active: "live"), ["a", "orphan"])
    }

    func testTheFileRoundTripsAndReadsTheOlderFormat() throws {
        let file = temp().appendingPathComponent(Outbox.fileName)
        var o = Outbox()
        o.begin(rec("a"))
        o.begin(rec("b"))
        o.finish("b", end: t0, title: nil)
        o.markSent("b", store: "icloud", at: t0)
        try o.save(to: file)
        XCTAssertEqual(try Outbox.load(from: file), o)

        let old = #"[{"recording":{"id":"x","start":0,"end":60},"sent":true},{"recording":{"id":"y","start":0,"end":60},"sent":false}]"#
        try Data(old.utf8).write(to: file)
        let read = try Outbox.load(from: file)
        XCTAssertTrue(read["x"]?.isSent ?? false)
        if case .sent(let store, _) = read["x"]?.state { XCTAssertNil(store) }
        XCTAssertEqual(read["y"]?.state, .waiting)
    }

    func testAnUnreadableFileIsSetAsideNotReplaced() throws {
        let dir = temp()
        let file = dir.appendingPathComponent(Outbox.fileName)
        try Data("{not json".utf8).write(to: file)
        XCTAssertThrowsError(try Outbox.load(from: file))
        let (o, aside) = Outbox.loadOrSetAside(from: file, now: t0)
        XCTAssertEqual(o.entries, [])
        XCTAssertNotNil(aside)
        XCTAssertTrue(aside!.lastPathComponent.hasPrefix("outbox.unreadable-"))
        XCTAssertEqual(try String(contentsOf: aside!, encoding: .utf8), "{not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Outbox.load(from: file), Outbox(), "A missing file is an empty outbox")
    }
}
