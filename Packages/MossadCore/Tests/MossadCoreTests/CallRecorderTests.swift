import AVFoundation
import CoreAudio
import XCTest
@testable import MossadCore

final class FakeSource: TrackSource, @unchecked Sendable {
    var seconds: Double = 0
    var amplitude: Double = 0.5
    var failStarts = 0
    private(set) var started = false
    private(set) var stopped = false
    private(set) var startCalls = 0
    var log: ((String) -> Void)?
    var name = ""
    var failureHandler: (() -> Void)?
    func onFailure(_ handler: @escaping () -> Void) { failureHandler = handler }
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        startCalls += 1
        log?(name)
        if failStarts > 0 { failStarts -= 1; throw Boom() }
        started = true
        if seconds > 0 { onBuffer(sineBuffer(seconds: seconds, sampleRate: 16_000, channels: 1, amplitude: amplitude)) }
    }
    func stop() { stopped = true }
}

final class CallRecorderTests: XCTestCase {
    var paths: Paths!
    let them = FakeSource()
    let me = FakeSource()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date!
    var themMade: [[AudioObjectID]] = []
    lazy var recorder = CallRecorder(paths: paths, makeThem: { self.themMade.append($0); return self.them }, makeMe: { self.me }, clock: { self.now })

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
        them.amplitude = 0
        me.seconds = 120
        me.amplitude = 0
        now = t0.addingTimeInterval(120)
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(280), trimTo: t0.addingTimeInterval(100)))
        XCTAssertEqual(r.end, t0.addingTimeInterval(100))
        for track in [Track.me, .them] {
            XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent(track.fileName)), 100, accuracy: 0.05)
        }
    }

    func testFallbackEndKeepsRemoteSpeechAfterTheMicWentIdle() throws {
        them.seconds = 150
        me.seconds = 100
        now = t0.addingTimeInterval(150)
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(330), trimTo: t0.addingTimeInterval(30)))
        XCTAssertEqual(r.end.timeIntervalSince(t0), 150, accuracy: 1)
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("them.caf")), 150, accuracy: 1)
    }

    func testFallbackEndKeepsOwnSpeechAfterTheAppReleasedTheMic() throws {
        them.seconds = 120
        them.amplitude = 0
        me.seconds = 120
        now = t0.addingTimeInterval(120)
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(300), trimTo: t0.addingTimeInterval(30)))
        XCTAssertEqual(r.end.timeIntervalSince(t0), 120, accuracy: 1)
    }

    func testFailedTapStartWaitsBeforeTryingAgain() throws {
        them.failStarts = 1
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        now = t0.addingTimeInterval(2)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(them.startCalls, 1)
    }

    func testTapIsNotStartedWithoutSystemAudioPermission() throws {
        var allowed = false
        let recorder = CallRecorder(paths: paths, makeThem: { self.themMade.append($0); return self.them }, makeMe: { self.me },
                                    clock: { self.now }, systemAudioAllowed: { allowed })
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        XCTAssertEqual(themMade, [])
        allowed = true
        now = t0.addingTimeInterval(CallRecorder.retryInterval)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(themMade, [[5]])
    }

    func testFailedTapStartIsRetriedOnTheNextTick() throws {
        them.failStarts = 1
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        XCTAssertFalse(them.started)
        now = t0.addingTimeInterval(CallRecorder.retryInterval)
        recorder.updateThemProcesses([5])
        XCTAssertTrue(them.started)
        XCTAssertEqual(themMade, [[5], [5]])
    }

    func testFailedMicStartIsRetriedOnTheNextTick() throws {
        me.failStarts = 1
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        XCTAssertFalse(me.started)
        now = t0.addingTimeInterval(CallRecorder.retryInterval)
        recorder.updateThemProcesses([5])
        XCTAssertTrue(me.started)
    }

    func testMicStartsBeforeTheTap() throws {
        var order: [String] = []
        me.name = "me"; them.name = "them"
        me.log = { order.append($0) }; them.log = { order.append($0) }
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        XCTAssertEqual(order, ["me", "them"])
    }

    func testAFailedMicRestartIsRetried() throws {
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        me.failureHandler?()
        now = t0.addingTimeInterval(CallRecorder.retryInterval)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(me.startCalls, 2)
    }

    func testBeginThatCannotCreateItsFilesLeavesNoCall() throws {
        let id = CallRecorder.callID(for: t0)
        try FileManager.default.createDirectory(at: paths.callDirectory(id).appendingPathComponent("me.caf"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0))
        XCTAssertFalse(recorder.isRecording)
    }

    func testBeginWhileRecordingKeepsThePreviousCall() throws {
        let first = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(300)
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [2], at: t0.addingTimeInterval(300))
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(first)).status, .recorded)
    }

    func testRebuildThemRestartsTapWithSameProcesses() throws {
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5, 6], at: t0)
        recorder.rebuildThem()
        XCTAssertEqual(themMade, [[5, 6], [5, 6]])
        XCTAssertTrue(them.stopped)
    }

    func testRebuildThemWhenIdleDoesNothing() {
        recorder.rebuildThem()
        XCTAssertEqual(themMade, [])
    }
}
