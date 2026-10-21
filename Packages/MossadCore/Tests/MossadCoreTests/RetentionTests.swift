import XCTest
@testable import MossadCore

final class RetentionTests: XCTestCase {
    var paths: Paths!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func call(_ id: String, _ status: CallStatus, endedDaysAgo days: Double) throws -> URL {
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let end = now.addingTimeInterval(-days * 86_400)
        try CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: end.addingTimeInterval(-600), end: end, status: status).save(to: dir)
        for f in ["me.caf", "them.caf", "clip-them-A.caf"] { try Data([1]).write(to: dir.appendingPathComponent(f)) }
        return dir
    }

    func exists(_ dir: URL, _ f: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) }

    func testDeletesOldWrittenAudioKeepsJSON() throws {
        let dir = try call("old", .written, endedDaysAgo: 31)
        Retention.sweep(audioRoot: paths.audio, olderThan: 30, now: now)
        XCTAssertFalse(exists(dir, "me.caf") || exists(dir, "them.caf") || exists(dir, "clip-them-A.caf"))
        XCTAssertTrue(exists(dir, "call.json"))
    }

    func testKeepsUnwrittenEvenIfOld() throws {
        let dir = try call("stuck", .recorded, endedDaysAgo: 40)
        Retention.sweep(audioRoot: paths.audio, olderThan: 30, now: now)
        XCTAssertTrue(exists(dir, "me.caf"))
    }

    func testKeepsRecent() throws {
        let dir = try call("new", .written, endedDaysAgo: 29)
        Retention.sweep(audioRoot: paths.audio, olderThan: 30, now: now)
        XCTAssertTrue(exists(dir, "them.caf"))
    }
}

final class MeetingIndexTests: XCTestCase {
    var paths: Paths!

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, title) in ["Weekly Ops Sync", "Vendor call", "Forecast review"].enumerated() {
            let id = "call\(i)"
            let dir = paths.callDirectory(id)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: base.addingTimeInterval(Double(i) * 3600),
                               end: base.addingTimeInterval(Double(i) * 3600 + 600), status: .written)
            r.calendarTitle = title
            r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 2, text: i == 0 ? "Adirondack chairs ship Friday" : "Other topic")]
            try! r.save(to: dir)
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testAllNewestFirst() {
        XCTAssertEqual(MeetingIndex(paths: paths).all().map(\.title), ["Forecast review", "Vendor call", "Weekly Ops Sync"])
    }

    func testSearchMatchesTitleAndText() {
        let index = MeetingIndex(paths: paths)
        XCTAssertEqual(index.search("vendor").map(\.title), ["Vendor call"])
        XCTAssertEqual(index.search("ADIRONDACK").map(\.title), ["Weekly Ops Sync"])
        XCTAssertEqual(index.search("").count, 3)
    }
}

final class VoiceLibraryEditTests: XCTestCase {
    func testRenameMergeDelete() throws {
        let dir = tempDirectory()
        let lib = VoiceLibrary(directory: dir)
        try lib.add([1, 0, 0], to: "Josh")
        try lib.add([0, 1, 0], to: "Amy Lee")
        try lib.add([0.9, 0.1, 0], to: "J. Smith")
        try lib.rename("Josh", to: "Alex Rivera")
        XCTAssertEqual(lib.profiles.map(\.name), ["Alex Rivera", "Amy Lee", "J. Smith"])
        try lib.merge("J. Smith", into: "Alex Rivera")
        XCTAssertEqual(lib.profiles.map(\.name), ["Alex Rivera", "Amy Lee"])
        XCTAssertEqual(lib.profiles[0].embeddings.count, 2)
        try lib.delete("Amy Lee")
        XCTAssertEqual(VoiceLibrary(directory: dir).profiles.map(\.name), ["Alex Rivera"])
    }
}
