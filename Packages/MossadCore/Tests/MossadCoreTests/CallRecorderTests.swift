import AVFoundation
import CoreAudio
import XCTest
@testable import MossadCore

final class FakeSource: TrackSource, @unchecked Sendable {
    var seconds: Double = 0
    private(set) var started = false
    private(set) var stopped = false
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        started = true
        if seconds > 0 { onBuffer(sineBuffer(seconds: seconds, sampleRate: 16_000, channels: 1)) }
    }
    func stop() { stopped = true }
}

final class CallRecorderTests: XCTestCase {
    var paths: Paths!
    let them = FakeSource()
    let me = FakeSource()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date!
    lazy var recorder = CallRecorder(paths: paths, makeThem: { _ in self.them }, makeMe: { self.me }, clock: { self.now })

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        now = t0
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func testCallIDFromStartTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 30, second: 5))!
        XCTAssertEqual(CallRecorder.callID(for: start), "20261020-143005")
    }

    func testBeginWritesRecordWithStatusRecording() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        let r = try CallRecord.load(from: paths.callDirectory(id))
        XCTAssertEqual(r.status, .recording)
        XCTAssertTrue(them.started && me.started)
    }

    func testShortCallIsDiscarded() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        XCTAssertNil(recorder.end(at: t0.addingTimeInterval(59), trimTo: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
        XCTAssertTrue(them.stopped && me.stopped)
    }

    func testEndWritesRecordWithStatusRecorded() throws {
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(61), trimTo: nil))
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.end, t0.addingTimeInterval(61))
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)), r)
        for track in [Track.me, .them] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.callDirectory(id).appendingPathComponent(track.fileName).path))
        }
    }

    func testSkipDeletesEverything() throws {
        let id = try recorder.begin(platform: .teams, bundleID: "com.microsoft.teams2", processIDs: [1], at: t0)
        recorder.skip()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
        XCTAssertTrue(them.stopped && me.stopped)
        XCTAssertFalse(recorder.isRecording)
    }

    func testFallbackEndTrimsBothTracks() throws {
        them.seconds = 120
        me.seconds = 120
        now = t0.addingTimeInterval(120)
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(280), trimTo: t0.addingTimeInterval(100)))
        XCTAssertEqual(r.end, t0.addingTimeInterval(100))
        for track in [Track.me, .them] {
            XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent(track.fileName)), 100, accuracy: 0.05)
        }
    }
}
