import XCTest
@testable import MossadCore

/// A frame source that the test drives by hand.
final class FakeFrames: FrameSource, @unchecked Sendable {
    struct Picture: FramePicture {
        let gray: UInt8
        var fails = false
        var failsWrite = false
        var thumb: FrameThumb? { FrameThumb(pixels: [UInt8](repeating: gray, count: FrameThumb.width * FrameThumb.height)) }
        func held() -> HeldPicture? { fails ? nil : Held(gray: gray, fails: failsWrite) }
    }

    final class Held: HeldPicture {
        let gray: UInt8
        let fails: Bool
        init(gray: UInt8, fails: Bool = false) { self.gray = gray; self.fails = fails }
        func write(to url: URL) -> Bool { !fails && (try? Data([gray]).write(to: url)) != nil }
    }

    private(set) var handler: ((FrameEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    var windowSight: WindowSight? = .visible
    /// The old two-way switch of the tests: off is a hidden window.
    var windowOnScreen: Bool? {
        get { windowSight.map { $0 == .visible } }
        set { windowSight = newValue.map { $0 ? .visible : .hidden } }
    }
    var window = "us.zoom.xos#1"

    func start(_ handler: @escaping (FrameEvent) -> Void) {
        starts += 1
        self.handler = handler
    }

    func stop() {
        stops += 1
        handler = nil
    }

    func show(_ gray: UInt8) { handler?(.picture(Picture(gray: gray, fails: failsCopy, failsWrite: failsWrite), window: window)) }
    func idle() { handler?(.idle) }
    func lose() { handler?(.lost) }
    var failsCopy = false
    var failsWrite = false
}

final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
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
    let setting = Switch()
    let clock = OffsetClock()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// Wall seconds that the recording's own time leaves out (a pause).
    var pausedSeconds: TimeInterval = 0
    final class Presenter: @unchecked Sendable {
        var reads = 0
        var name: String? = "Sam Carter"
        /// The read gives no answer, as when the app is busy.
        var unknown = false
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
        let clock = clock, shown = shown, setting = setting, t0 = t0
        let reader: @Sendable () -> PresenterRead = {
            shown.reads += 1
            if shown.unknown { return .unknown }
            return shown.name.map { .name($0) } ?? .none
        }
        let read = presenter ? reader : nil
        nonisolated(unsafe) let test = self
        return ScreenRecorder(dir: dir, source: source, offset: { clock.now }, now: { t0.addingTimeInterval(clock.now + test.pausedSeconds) },
                              isEnabled: { setting.isOn }, presenter: read, usesTimer: false, runPresenter: { $0() })
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
        // The time of day is saved to the second.
        XCTAssertEqual(index?.frames.first?.time?.timeIntervalSince(t0) ?? 0, 12.5, accuracy: 1)
        var frame = index?.frames.first
        frame?.time = nil
        XCTAssertEqual(frame, .init(offset: 12.5, file: "12500.heic", window: "us.zoom.xos#1", session: 0))
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

    func keep(_ gray: UInt8, at t: TimeInterval) {
        clock.now = t
        source.show(gray)
        clock.now = t + 3
        source.show(gray)
    }

    func testAWindowThatGoesAwayLeavesOnePauseAndOneReturn() {
        let screen = make()
        screen.start()
        clock.now = 5
        source.show(40)
        source.windowOnScreen = false
        for t in stride(from: 8.0, through: 60, by: 3) {
            clock.now = t
            screen.tick()
        }
        XCTAssertEqual(index?.gaps, [ScreenGap(offset: 5, paused: true)])
        clock.now = 70
        source.windowOnScreen = true
        source.show(40)
        clock.now = 73
        source.idle()
        XCTAssertEqual(index?.gaps, [ScreenGap(offset: 5, paused: true), ScreenGap(offset: 70, paused: false)])
    }

    func testACoveredWindowThatOnlySendsIdleFramesIsAPause() {
        // The window server still lists a covered window, and the stream still sends idle frames for it.
        let screen = make()
        screen.start()
        clock.now = 5
        source.show(40)
        source.windowSight = .covered
        for t in stride(from: 8.0, through: 30, by: 3) {
            clock.now = t
            source.idle()
            screen.tick()
        }
        XCTAssertEqual(index?.gaps, [ScreenGap(offset: 5, paused: true)])
        // Uncovered again: the next check says so, with no new picture.
        source.windowSight = .visible
        clock.now = 33
        screen.tick()
        XCTAssertEqual(index?.gaps?.last, ScreenGap(offset: 33, paused: false))
    }

    /// Runs the 3 s timer and, at each 90 s, a new slide that stays.
    func slides(_ screen: ScreenRecorder, from: TimeInterval, count: Int) {
        for n in 0..<count {
            let at = from + Double(n) * 90
            for t in stride(from: at - 87, to: at, by: 3) where t > 0 {
                clock.now = t
                source.idle()
                screen.tick()
            }
            clock.now = at
            source.show(UInt8(40 + (n % 4) * 60))
        }
    }

    func testACoveredWindowThatStillDrawsIsOneSessionWithNoPauses() {
        // The owner's notes are in front of the Zoom window for the whole share. Zoom draws on.
        let screen = make(presenter: true)
        screen.start()
        clock.now = 3
        source.windowSight = .covered
        screen.tick()
        // The first picture while covered proves that the app draws.
        slides(screen, from: 5, count: 6)
        clock.now = 470
        screen.tick()
        XCTAssertNil(index?.gaps)
        XCTAssertEqual(index?.frames.count, 6)
        XCTAssertEqual(Set(index?.frames.compactMap(\.session) ?? []), [0])
    }

    func testCoverThatBeginsDuringAShareDoesNotEndTheSession() {
        let screen = make()
        screen.start()
        keep(250, at: 10)
        // Now the notes window goes in front. The next slide comes 90 s later.
        source.windowSight = .covered
        slides(screen, from: 100, count: 4)
        clock.now = 380
        screen.tick()
        // One pause, until the first slide showed that the app draws; then none. All one session.
        XCTAssertEqual(index?.gaps, [ScreenGap(offset: 13, paused: true), ScreenGap(offset: 100, paused: false)])
        XCTAssertEqual(index?.frames.map(\.session), [0, 0, 0, 0, 0])
    }

    func testACoveredWindowWithNoPictureForFiveMinutesEndsTheSession() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        source.windowSight = .covered
        for t in stride(from: 16.0, through: 400, by: 3) {
            clock.now = t
            screen.tick()
        }
        keep(200, at: 420)
        XCTAssertEqual(index?.frames.map(\.session), [0, 1])
    }

    func testAPresenterReadWithNoAnswerChangesNothing() {
        let screen = make(presenter: true)
        screen.start()
        keep(40, at: 10)
        keep(120, at: 30)
        // The app is busy: the walk was cut short. That is not "no name".
        shown.unknown = true
        keep(220, at: 75)
        keep(40, at: 90)
        XCTAssertEqual(index?.frames.map(\.presenter), ["Sam Carter", "Sam Carter", "Sam Carter", "Sam Carter"])
        XCTAssertEqual(index?.frames.map(\.session), [0, 0, 0, 0])
        // It asks again sooner than a minute later, but not at each kept frame: 20 s after the read with no answer.
        XCTAssertEqual(presenterReads, 2)
        shown.unknown = false
        keep(120, at: 105)
        XCTAssertEqual(presenterReads, 3)
        XCTAssertEqual(index?.frames.map(\.session), [0, 0, 0, 0, 0])
    }

    func testReadsWithNoAnswerComeLessAndLessOften() {
        let screen = make(presenter: true)
        screen.start()
        shown.unknown = true
        // A kept frame each 10 s for 5 minutes, and the app never answers.
        for n in 0..<30 { keep(UInt8(40 + (n % 4) * 60), at: 10 + Double(n) * 10) }
        // At 10 s, then 20 s, 40 s, and 60 s apart: 10, 30, 70, 130, 190, 250. Not 30 walks.
        XCTAssertEqual(presenterReads, 6)
        XCTAssertEqual(Set(index?.frames.compactMap(\.session) ?? []), [0])
    }

    func testAFirstReadWithNoAnswerIsStillTheSessionsOwnWhenItComes() {
        let screen = make(presenter: true)
        screen.start()
        shown.unknown = true
        keep(40, at: 10)
        shown.unknown = false
        keep(120, at: 30)
        // The name is the session's from its first frame; the late answer does not split it.
        XCTAssertEqual(index?.frames.map(\.presenter), ["Sam Carter", "Sam Carter"])
        XCTAssertEqual(index?.frames.map(\.session), [0, 0])
    }

    func testAQuietWindowOnScreenLeavesNoPause() {
        let screen = make()
        screen.start()
        for t in stride(from: 3.0, through: 300, by: 3) {
            clock.now = t
            screen.tick()
        }
        XCTAssertNil(index)
    }

    func testTurningTheSettingOffEndsTheCaptureAtOnce() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        clock.now = 30
        source.show(200)
        setting.isOn = false
        // The next frame or tick sees it: the stream stops, and the waiting picture goes too. It is the one the
        // owner wanted to stop.
        clock.now = 33
        screen.tick()
        XCTAssertEqual(source.stops, 1)
        XCTAssertNil(source.handler)
        // Turning it on again in the same call does not start it again.
        setting.isOn = true
        screen.start()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(index?.frames.map(\.offset), [10])
        XCTAssertEqual(files, ["10000.heic"])
    }

    func testAStopRightAfterTheSettingWentOffDoesNotKeepTheWaitingPicture() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        clock.now = 30
        source.show(200)
        // Off, and the call ends before the next frame or check could see it.
        setting.isOn = false
        screen.close()
        XCTAssertEqual(index?.frames.map(\.offset), [10])
        XCTAssertEqual(files, ["10000.heic"])
    }

    func testNoCaptureStartsWithTheSettingOff() {
        setting.isOn = false
        let screen = make()
        screen.start()
        XCTAssertEqual(source.starts, 0)
    }

    func testSlidesMinutesApartAreOneSessionAndThePresenterIsReadAtItsStart() {
        let screen = make(presenter: true)
        screen.start()
        keep(40, at: 10)
        keep(120, at: 30)
        XCTAssertEqual(presenterReads, 1)
        // 90 s and then 3 minutes on one slide: still the same share. The name is read again, and it is the same.
        keep(220, at: 120)
        keep(40, at: 300)
        XCTAssertEqual(index?.frames.map(\.session), [0, 0, 0, 0])
        XCTAssertEqual(index?.frames.map(\.presenter), ["Sam Carter", "Sam Carter", "Sam Carter", "Sam Carter"])
        XCTAssertEqual(presenterReads, 3)
    }

    func testAnotherPresenterWithNoGapGetsTheirOwnSession() {
        let screen = make(presenter: true)
        screen.start()
        keep(40, at: 10)
        keep(120, at: 30)
        // Dana takes over at once. The next read, a minute after the first, shows her name.
        presenterName = "Dana Lee"
        keep(220, at: 75)
        keep(40, at: 90)
        XCTAssertEqual(index?.frames.map(\.presenter), ["Sam Carter", "Sam Carter", "Dana Lee", "Dana Lee"])
        XCTAssertEqual(index?.frames.map(\.session), [0, 0, 1, 1])
        // Then the app shows no name: those frames carry none.
        presenterName = nil
        keep(120, at: 140)
        XCTAssertEqual(index?.frames.last?.presenter, nil)
        XCTAssertEqual(index?.frames.last?.session, 2)
    }

    func testAFrameBeforeTheShareDoesNotHideThePresenter() {
        let screen = make(presenter: true)
        screen.start()
        // The gallery, before anyone shares: no name.
        presenterName = nil
        keep(40, at: 10)
        presenterName = "Sam Carter"
        keep(120, at: 30)
        keep(220, at: 75)
        XCTAssertEqual(index?.frames.map(\.presenter), [nil, nil, "Sam Carter"])
        XCTAssertEqual(index?.frames.map(\.session), [0, 0, 1])
    }

    func testAPauseOfTheCaptureAndAnotherWindowStartNewSessions() {
        let screen = make(presenter: true)
        screen.start()
        keep(40, at: 10)
        // The window is gone for a while.
        source.windowOnScreen = nil
        for t in stride(from: 16.0, through: 40, by: 3) {
            clock.now = t
            screen.tick()
        }
        source.windowOnScreen = true
        keep(120, at: 50)
        // The owner's own pause.
        screen.stop()
        screen.start()
        keep(220, at: 70)
        source.window = "us.zoom.xos#2"
        keep(40, at: 90)
        XCTAssertEqual(index?.frames.map(\.session), [0, 1, 2, 3])
        XCTAssertEqual(presenterReads, 4)
    }

    func testTheTimeOfDayIsSavedWithTheFrame() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        screen.stop()
        // A 10 minute pause: the recording's time stands still, the day goes on.
        pausedSeconds = 600
        screen.start()
        keep(200, at: 20)
        XCTAssertEqual(index?.frames.map(\.time), [t0.addingTimeInterval(10), t0.addingTimeInterval(620)])
    }

    func testAPictureTakenJustBeforeTheWindowWasLostIsNotKept() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        // A frame composed right after a click on another tab, while the title still said "meeting".
        clock.now = 30
        source.show(200)
        source.lose()
        clock.now = 40
        screen.tick()
        XCTAssertEqual(index?.frames.map(\.offset), [10])
    }

    func testTheCheckOfTheWindowComesBeforeAWaitingPictureIsKept() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        // A new picture, and then the 3 s check finds that the window is not the meeting's any more (or that the
        // page moved in it): the picture must not be kept by that same check.
        clock.now = 30
        source.show(200)
        source.windowSight = nil
        clock.now = 36
        screen.tick()
        XCTAssertEqual(index?.frames.map(\.offset), [10])
        source.lose()
        clock.now = 60
        source.windowSight = .visible
        screen.tick()
        XCTAssertEqual(index?.frames.map(\.offset), [10])
    }

    func testAFailedWriteDoesNotCountAsKept() {
        let screen = make()
        screen.start()
        source.failsWrite = true
        keep(40, at: 10)
        XCTAssertNil(index)
        source.failsWrite = false
        keep(40, at: 20)
        XCTAssertEqual(index?.frames.map(\.offset), [20])
    }

    func testTrimAlsoDropsLaterPauses() {
        let screen = make()
        screen.start()
        keep(40, at: 10)
        source.windowOnScreen = false
        for t in stride(from: 16.0, through: 40, by: 3) {
            clock.now = t
            screen.tick()
        }
        screen.close()
        screen.trim(to: 12)
        XCTAssertEqual(index?.gaps, [])
        XCTAssertEqual(index?.frames.map(\.offset), [10])
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
        return ScreenRecorder(dir: call.directory, source: self.source, offset: call.offset, usesTimer: false)
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

    func testTheAudioStopsBeforeTheLastPictureIsWritten() throws {
        final class Order: @unchecked Sendable { var events: [String] = [] }
        final class Screens: ScreenCapturing {
            let order: Order
            init(_ order: Order) { self.order = order }
            func start() {}
            func stop() { order.events.append("screens") }
            func close() { order.events.append("screens") }
            func trim(to length: TimeInterval) {}
        }
        let order = Order()
        me.log = { _ in }
        let recorder = CallRecorder(paths: paths, makeThem: { _ in self.them }, makeMe: { self.me }, clock: { self.now },
                                    captureClock: .following { self.now }, makeScreens: { _ in Screens(order) })
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(30)
        recorder.pause()
        XCTAssertTrue(me.stopped && them.stopped)
        XCTAssertEqual(order.events, ["screens"])
        recorder.resume()
        recorder.skip()
        XCTAssertEqual(order.events, ["screens", "screens"])
    }

    func testAMissingWindowIsKeptAsAPauseAndNotAsAMarkerOfTheCall() throws {
        var screen: ScreenRecorder?
        let recorder = CallRecorder(paths: paths, makeThem: { _ in self.them }, makeMe: { self.me }, clock: { self.now },
                                    captureClock: .following { self.now }, makeScreens: { call in
            screen = ScreenRecorder(dir: call.directory, source: self.source, offset: call.offset, usesTimer: false)
            return screen
        })
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        source.windowOnScreen = nil
        for s in stride(from: 3.0, through: 30, by: 3) {
            now = t0.addingTimeInterval(s)
            screen?.tick()
        }
        // Nobody shared anything: the note says nothing about the screen.
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).markers, [])
        XCTAssertEqual(index(id)?.gaps, [ScreenGap(offset: 0, paused: true)])
        recorder.skip()
    }

    func testARecoveredCallHasNoFramesAfterItsAudio() throws {
        let id = "20261020-143000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 90, [(0, 10, 200)])
        try CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0, status: .recording).save(to: dir)
        var frames = FrameIndex()
        for o in [30.0, 120] {
            let f = FrameIndex.Frame(offset: o, file: FrameIndex.fileName(offset: o))
            frames.insert(f)
            try Data([1]).write(to: frames.url(of: f, in: dir))
        }
        try frames.save(to: dir)
        ProcessingQueue(paths: paths).recoverInterrupted()
        XCTAssertEqual(try CallRecord.load(from: dir).status, .recorded)
        XCTAssertEqual(index(id)?.frames.map(\.offset), [30])
    }
}
