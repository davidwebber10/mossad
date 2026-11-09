import XCTest
@testable import MossadCore

/// A frame source that the test drives by hand.
final class FakeFrames: FrameSource, @unchecked Sendable {
    struct Picture: FramePicture {
        let gray: UInt8
        var thumb: FrameThumb? { FrameThumb(pixels: [UInt8](repeating: gray, count: FrameThumb.width * FrameThumb.height)) }
        func held() -> HeldPicture? { Held(gray: gray) }
    }

    final class Held: HeldPicture {
        let gray: UInt8
        init(gray: UInt8) { self.gray = gray }
        func write(to url: URL) -> Bool { (try? Data([gray]).write(to: url)) != nil }
    }

    private(set) var handler: ((FrameEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    var windowOnScreen: Bool? = true
    var window = "us.zoom.xos#1"

    func start(_ handler: @escaping (FrameEvent) -> Void) {
        starts += 1
        self.handler = handler
    }

    func stop() {
        stops += 1
        handler = nil
    }

    func show(_ gray: UInt8) { handler?(.picture(Picture(gray: gray), window: window)) }
    func idle() { handler?(.idle) }
}

final class MarkerList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [TranscriptMarker] = []
    var all: [TranscriptMarker] { lock.withLock { list } }
    func add(_ offset: TimeInterval, _ text: String) { lock.withLock { list.append(TranscriptMarker(offset: offset, text: text)) } }
}

final class OffsetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class ScreenRecorderTests: XCTestCase {
    var dir: URL!
    let source = FakeFrames()
    let markers = MarkerList()
    let clock = OffsetClock()
    final class Presenter: @unchecked Sendable {
        var reads = 0
        var name: String? = "Sam Carter"
    }
    let shown = Presenter()
    var presenterReads: Int { shown.reads }
    var presenterName: String? {
        get { shown.name }
        set { shown.name = newValue }
    }

    override func setUp() {
        dir = tempDirectory()
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func make(presenter: Bool = false) -> ScreenRecorder {
        let clock = clock, markers = markers, shown = shown
        let reader: @Sendable () -> String? = { shown.reads += 1; return shown.name }
        let read = presenter ? reader : nil
        return ScreenRecorder(dir: dir, source: source, offset: { clock.now }, addMarker: { markers.add($0, $1) },
                              presenter: read, usesTimer: false, runPresenter: { $0() })
    }

    var index: FrameIndex? { FrameIndex.load(from: dir) }
    var files: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: FrameIndex.folder(in: dir).path)) ?? []).sorted() }

    func testKeepsAStablePictureAtItsOffsetAndWritesTheIndex() {
        let screen = make()
        screen.start()
        XCTAssertNil(index)
        clock.now = 12.5
        source.show(40)
        XCTAssertEqual(files, [])
        clock.now = 15.5
        source.idle()
        XCTAssertEqual(files, [])
        clock.now = 18
        source.idle()
        XCTAssertEqual(files, ["12500.heic"])
        XCTAssertEqual(index?.frames, [.init(offset: 12.5, file: "12500.heic", window: "us.zoom.xos#1")])
    }

    func testTheTimerKeepsAPictureWhenTheWindowSendsNothingMore() {
        let screen = make()
        screen.start()
        source.show(40)
        clock.now = 6
        screen.tick()
        XCTAssertEqual(files, ["0.heic"])
    }

    func testStopKeepsTheWaitingPictureAndNothingIsTakenAfterIt() {
        let screen = make()
        screen.start()
        clock.now = 30
        source.show(40)
        let handler = source.handler
        screen.stop()
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(files, ["30000.heic"])
        // A frame that was already on its way when the pause came.
        clock.now = 31
        handler?(.picture(FakeFrames.Picture(gray: 200), window: "w"))
        screen.tick()
        clock.now = 60
        handler?(.idle)
        XCTAssertEqual(files, ["30000.heic"])
        // After the pause the capture runs again, on the recording's own time.
        screen.start()
        XCTAssertEqual(source.starts, 2)
        clock.now = 45
        source.show(200)
        clock.now = 48
        source.show(200)
        XCTAssertEqual(index?.frames.map(\.offset), [30, 45])
    }

    func testCloseEndsTheCaptureForGood() {
        let screen = make()
        screen.start()
        screen.close()
        screen.start()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 1)
    }

    func testTrimDropsFramesAfterTheEndOfTheAudio() {
        let screen = make()
        screen.start()
        for (t, gray) in [(10.0, UInt8(40)), (50, 120), (90, 220)] {
            clock.now = t
            source.show(gray)
            clock.now = t + 3
            source.show(gray)
        }
        screen.close()
        screen.trim(to: 60)
        XCTAssertEqual(index?.frames.map(\.offset), [10, 50])
        XCTAssertEqual(files, ["10000.heic", "50000.heic"])
    }

    func testAWindowThatGoesAwayLeavesOnePausedAndOneResumedMarker() {
        let screen = make()
        screen.start()
        clock.now = 5
        source.show(40)
        source.windowOnScreen = false
        for t in stride(from: 8.0, through: 60, by: 3) {
            clock.now = t
            screen.tick()
        }
        XCTAssertEqual(markers.all, [TranscriptMarker(offset: 5, text: "Screen capture paused")])
        clock.now = 70
        source.windowOnScreen = true
        source.show(40)
        clock.now = 73
        source.idle()
        XCTAssertEqual(markers.all.map(\.text), ["Screen capture paused", "Screen capture resumed"])
        XCTAssertEqual(markers.all.last?.offset, 70)
    }

    func testAQuietWindowOnScreenLeavesNoMarker() {
        let screen = make()
        screen.start()
        for t in stride(from: 3.0, through: 300, by: 3) {
            clock.now = t
            screen.tick()
        }
        XCTAssertEqual(markers.all, [])
    }

    func testThePresenterIsReadOncePerShareSession() {
        let screen = make(presenter: true)
        screen.start()
        func keep(_ gray: UInt8, at t: TimeInterval) {
            clock.now = t
            source.show(gray)
            clock.now = t + 3
            source.show(gray)
        }
        keep(40, at: 10)
        keep(120, at: 30)
        keep(220, at: 60)
        XCTAssertEqual(presenterReads, 1)
        XCTAssertEqual(index?.frames.map(\.presenter), ["Sam Carter", "Sam Carter", "Sam Carter"])
        // More than a minute later it is a new session, and this time the app shows no name.
        presenterName = nil
        keep(40, at: 200)
        XCTAssertEqual(presenterReads, 2)
        XCTAssertEqual(index?.frames.last?.presenter, nil)
        // Another window is a new session too.
        source.window = "us.zoom.xos#2"
        keep(120, at: 220)
        XCTAssertEqual(presenterReads, 3)
    }
}

/// The recorder gives the shared screen the same rules as the audio.
final class CallRecorderScreenTests: XCTestCase {
    var paths: Paths!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date!
    let source = FakeFrames()
    let me = FakeSource(), them = FakeSource()
    var made: [ScreenCall] = []
    lazy var recorder = CallRecorder(paths: paths, makeThem: { _ in self.them }, makeMe: { self.me }, clock: { self.now },
                                     captureClock: .following { self.now }, makeScreens: { call in
        self.made.append(call)
        return ScreenRecorder(dir: call.directory, source: self.source, offset: call.offset, addMarker: call.addMarker, usesTimer: false)
    })

    override func setUp() {
        paths = Paths(root: tempDirectory())
        try! paths.ensureDirectories()
        now = t0
    }

    override func tearDown() { try? FileManager.default.removeItem(at: paths.root) }

    func keep(_ gray: UInt8, atSecond s: TimeInterval) {
        now = t0.addingTimeInterval(s)
        source.show(gray)
        now = t0.addingTimeInterval(s + 3)
        source.show(gray)
    }

    func index(_ id: String) -> FrameIndex? { FrameIndex.load(from: paths.callDirectory(id)) }

    func testOffsetsLeaveOutPausedTime() throws {
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], meetingID: "123", at: t0)
        XCTAssertEqual(made.first?.platform, .zoom)
        XCTAssertEqual(made.first?.meetingID, "123")
        keep(40, atSecond: 20)
        now = t0.addingTimeInterval(60)
        recorder.pause()
        XCTAssertEqual(source.stops, 1)
        XCTAssertNil(source.handler)
        now = t0.addingTimeInterval(160)
        recorder.resume()
        XCTAssertEqual(source.starts, 2)
        // 170 s on the wall clock is second 70 of the files.
        keep(200, atSecond: 170)
        XCTAssertEqual(index(id)?.frames.map(\.offset), [20, 70])
    }

    func testNoScreenCaptureForARoomRecording() throws {
        _ = try recorder.beginManual(at: t0)
        XCTAssertTrue(made.isEmpty)
        XCTAssertEqual(source.starts, 0)
    }

    func testSkipStopsTheCaptureAndTheFramesGoWithTheCall() throws {
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        keep(40, atSecond: 20)
        let handler = source.handler
        recorder.skip()
        XCTAssertEqual(source.stops, 1)
        handler?(.picture(FakeFrames.Picture(gray: 200), window: "w"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
    }

    func testAShortCallTakesItsFramesWithIt() throws {
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        keep(40, atSecond: 20)
        XCTAssertNil(recorder.end(at: t0.addingTimeInterval(40), trimTo: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(id).path))
        XCTAssertEqual(source.stops, 1)
    }

    func testFramesAfterATrimmedEndAreDropped() throws {
        them.seconds = 120
        them.amplitude = 0
        me.seconds = 120
        me.amplitude = 0
        now = t0.addingTimeInterval(120)
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        keep(40, atSecond: 150)
        keep(200, atSecond: 250)
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(280), trimTo: t0.addingTimeInterval(200)))
        XCTAssertEqual(r.end, t0.addingTimeInterval(200))
        XCTAssertEqual(index(id)?.frames.map(\.offset), [150])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FrameIndex.folder(in: paths.callDirectory(id)).path), ["150000.heic"])
    }

    func testAMissingWindowAddsOneMarkerToTheCall() throws {
        var screen: ScreenRecorder?
        let recorder = CallRecorder(paths: paths, makeThem: { _ in self.them }, makeMe: { self.me }, clock: { self.now },
                                    captureClock: .following { self.now }, makeScreens: { call in
            screen = ScreenRecorder(dir: call.directory, source: self.source, offset: call.offset, addMarker: call.addMarker, usesTimer: false)
            return screen
        })
        let id = try CaptureQueue.queue.sync { try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0) }
        source.windowOnScreen = nil
        for s in stride(from: 3.0, through: 30, by: 3) {
            now = t0.addingTimeInterval(s)
            screen?.tick()
        }
        CaptureQueue.queue.sync {}
        let markers = try CallRecord.load(from: paths.callDirectory(id)).markers
        XCTAssertEqual(markers, [TranscriptMarker(offset: 0, text: "Screen capture paused")])
        CaptureQueue.queue.sync { recorder.skip() }
    }
}
