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
    var isGlobal = false
    private(set) var feed: AudioFeed?
    func onFailure(_ handler: @escaping () -> Void) { failureHandler = handler }

    func start(_ feed: AudioFeed) throws {
        startCalls += 1
        log?(name)
        if failStarts > 0 { failStarts -= 1; throw Boom() }
        started = true
        self.feed = feed
        if seconds > 0 { send(seconds) }
    }

    /// Sends audio that ends now on the feed's clock, a second at a time, as a device does.
    func send(_ seconds: Double, amplitude: Double? = nil) {
        guard let feed else { return }
        let end = feed.now
        var sent = 0.0
        while sent < seconds {
            let n = min(1, seconds - sent)
            feed.push(sineBuffer(seconds: n, sampleRate: 16_000, channels: 1, amplitude: amplitude ?? self.amplitude), start: end - seconds + sent)
            feed.flush()
            sent += n
        }
    }

    func stop() { stopped = true }
}

final class ProblemList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CaptureProblem] = []
    var all: [CaptureProblem] { lock.withLock { list } }
    func add(_ p: CaptureProblem) { lock.withLock { list.append(p) } }
}

final class CallRecorderTests: XCTestCase {
    var paths: Paths!
    let them = FakeSource()
    let me = FakeSource()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date!
    var themMade: [[AudioObjectID]] = []
    let told = ProblemList()
    var problems: [CaptureProblem] { told.all }
    lazy var recorder = makeRecorder()

    /// When set, each tap the recorder makes is the next one of these, not `them`.
    var taps: [FakeSource] = []
    var silenceFails = false

    func makeRecorder(systemAudioAllowed: @escaping () -> Bool = { true }, micAllowed: @escaping () -> Bool = { true },
                      freeBytes: @escaping () -> Int64? = { nil }) -> CallRecorder {
        let recorder = CallRecorder(paths: paths, makeThem: {
            self.themMade.append($0)
            return self.taps.isEmpty ? self.them : self.taps.removeFirst()
        }, makeMe: { self.me }, clock: { self.now }, captureClock: .following { self.now },
                                    systemAudioAllowed: systemAudioAllowed, micAllowed: micAllowed, freeBytes: freeBytes,
                                    silenceMuted: { r, dir in
            if self.silenceFails { throw MutedAudio.NotSilenced(underlying: "No space left on device") }
            try MutedAudio.apply(to: &r, in: dir)
        })
        let told = told
        recorder.onProblem = { problem, _ in told.add(problem) }
        return recorder
    }

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

    func testBeginSavesTheMeetingID() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], meetingID: "abc-defg-hij", at: t0)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).meetingID, "abc-defg-hij")
    }

    func testPauseStopsBothSourcesAndTicksDoNotRestartThem() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        recorder.pause()
        XCTAssertTrue(recorder.isPaused)
        XCTAssertTrue(them.stopped && me.stopped)
        let starts = (them.startCalls, me.startCalls)
        now = t0.addingTimeInterval(60)
        recorder.updateThemProcesses([1, 2])
        recorder.rebuildThem()
        XCTAssertEqual(them.startCalls, starts.0)
        XCTAssertEqual(me.startCalls, starts.1)
    }

    func testPauseAndResumeLeaveAMarkerAtThePausePoint() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(120)
        recorder.pause()
        now = t0.addingTimeInterval(300)
        recorder.resume()
        let markers = try CallRecord.load(from: paths.callDirectory(id)).markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertTrue(markers[0].text.hasPrefix("Paused from "), markers[0].text)
        XCTAssertTrue(markers[0].text.hasSuffix("(3 min)"), markers[0].text)
    }

    func testStopByThePersonLeavesAMarkerAtTheEnd() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(600)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil, byPerson: true))
        XCTAssertTrue(r.markers.last?.text.hasPrefix("Recording stopped at ") == true)
    }

    func testABookmarkIsSavedAtOnceAsAFlaggedMarker() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(90)
        recorder.bookmark()
        let markers = try CallRecord.load(from: paths.callDirectory(id)).markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertTrue(markers[0].isBookmark)
        XCTAssertTrue(markers[0].text.hasPrefix("★ Bookmarked at "), markers[0].text)
    }

    func testABookmarkReturnsItsOffsetAndTakesANoteLater() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(90)
        let offset = try XCTUnwrap(recorder.bookmark())
        XCTAssertTrue(recorder.setBookmarkNote(at: offset, "  Ask Dana about the budget "))
        var markers = try CallRecord.load(from: paths.callDirectory(id)).markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].note, "Ask Dana about the budget")
        XCTAssertTrue(markers[0].text.hasPrefix("★ Bookmarked at "), markers[0].text)
        XCTAssertTrue(recorder.setBookmarkNote(at: offset, ""))
        markers = try CallRecord.load(from: paths.callDirectory(id)).markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertNil(markers[0].note)
    }

    func testABookmarkWhilePausedOrIdleDoesNothing() throws {
        XCTAssertNil(recorder.bookmark())
        XCTAssertFalse(recorder.setBookmarkNote(at: 5, "x"))
        recorder.bookmark()
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        recorder.pause()
        recorder.bookmark()
        XCTAssertTrue(try CallRecord.load(from: paths.callDirectory(id)).markers.isEmpty)
    }

    func testAnInPersonRecordingUsesTheMicOnlyAndIsManual() throws {
        let id = try recorder.beginManual(at: t0)
        XCTAssertTrue(recorder.isManual)
        XCTAssertTrue(me.started)
        XCTAssertFalse(them.started)
        recorder.updateThemProcesses([1, 2])
        XCTAssertFalse(them.started, "an in-person recording never taps a call app")
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).platform, .inPerson)
        now = t0.addingTimeInterval(600)
        _ = recorder.end(at: now, trimTo: nil, byPerson: true)
        XCTAssertFalse(recorder.isManual)
    }

    func testMuteLeavesAMarkerFromMuteToUnmute() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(60)
        recorder.setMuted(true)
        recorder.setMuted(true)  // a repeated state changes nothing
        now = t0.addingTimeInterval(240)
        recorder.setMuted(false)
        let markers = try CallRecord.load(from: paths.callDirectory(id)).markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertTrue(markers[0].text.hasPrefix("Muted from "), markers[0].text)
        XCTAssertTrue(markers[0].text.hasSuffix("(3 min)"), markers[0].text)
    }

    func testResumeStartsBothSourcesAgain() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        recorder.pause()
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
        XCTAssertEqual(them.startCalls, 2)
        XCTAssertEqual(me.startCalls, 2)
    }

    func testCalendarDetailsDuringTheCallAreSaved() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], meetingID: "abc-defg-hij", at: t0)
        recorder.setCalendar(title: "Tech Team Monthly Sync", attendees: ["a@example.com"], forCall: id)
        let r = try CallRecord.load(from: paths.callDirectory(id))
        XCTAssertEqual(r.calendarTitle, "Tech Team Monthly Sync")
        XCTAssertEqual(r.attendees, ["a@example.com"])
        XCTAssertEqual(recorder.currentRecord?.calendarTitle, "Tech Team Monthly Sync")
    }

    func testCalendarDetailsForAnEndedCallAreIgnored() throws {
        recorder.setCalendar(title: "Old", attendees: [], forCall: "20000101-000000")
        XCTAssertNil(recorder.currentRecord)
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
        let recorder = makeRecorder(systemAudioAllowed: { allowed })
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

    /// After AirPods connected, the restarted mic sent nothing and the rest of the call lost the owner's voice.
    func testAMicThatSendsNoAudioIsRestarted() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        now = t0.addingTimeInterval(CallRecorder.stallLimit + 1)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(me.startCalls, 2)
    }

    /// A room recording has no detection tick, so its own check restarts a mic that went silent.
    func testAnInPersonMicThatSendsNoAudioIsRestarted() throws {
        _ = try recorder.beginManual(at: t0)
        now = t0.addingTimeInterval(CallRecorder.stallLimit + 1)
        recorder.checkMic()
        XCTAssertEqual(me.startCalls, 2)
        XCTAssertFalse(them.started)
    }

    func testAMicThatSendsAudioIsLeftAlone() throws {
        me.seconds = 1
        now = t0.addingTimeInterval(1)
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        now = t0.addingTimeInterval(CallRecorder.stallLimit)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(me.startCalls, 1)
    }

    func testBeginThatCannotCreateItsFilesLeavesNoCall() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.audio.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.audio.path) }
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

    // MARK: Mute

    /// Sends a second of mic audio for each second from `from` to `to`, moving the clock along.
    private func speak(from: Int, to: Int, each: ((Int) -> Void)? = nil) {
        for second in from..<to {
            now = t0.addingTimeInterval(Double(second + 1))
            me.send(1)
            each?(second + 1)
        }
    }

    private func loudest(_ id: String, _ track: Track = .me, from: Double, to: Double) throws -> Float {
        try AudioSamples.read(paths.callDirectory(id).appendingPathComponent(track.fileName), from: from, to: to).map(abs).max() ?? 0
    }

    /// The mute state is polled, so the unmute is seen seconds late. The words in those seconds were replaced by
    /// silence for good. Now the track keeps them: the span ends before the time nobody watched.
    func testTheFirstWordsAfterAnUnmuteAreKept() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 20)
        recorder.setMuted(true)
        speak(from: 20, to: 60)
        recorder.setMuted(false)   // seen at 60 s; the owner unmuted and spoke some seconds before
        speak(from: 60, to: 120)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [MuteSpan(start: 20, end: 60 - CallRecorder.unmuteLead)])
        XCTAssertGreaterThan(try loudest(id, from: 10, to: 19.9), 0.3)
        XCTAssertEqual(try loudest(id, from: 20.1, to: 56.9), 0, "the muted time is silence in the saved track")
        XCTAssertGreaterThan(try loudest(id, from: 57.1, to: 60), 0.3, "the seconds before the unmute was seen are kept")
        XCTAssertGreaterThan(try loudest(id, from: 60, to: 119), 0.3)
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("me.caf")), 120, accuracy: 0.1)
        XCTAssertEqual(r.markers.filter { $0.text.hasPrefix("Muted from ") }.count, 1)
    }

    /// The detector says when it last saw "muted": the span ends exactly there, with nothing more taken off.
    func testAMuteSpanEndsExactlyWhenMutedWasLastSeen() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 20)
        recorder.setMuted(true)
        speak(from: 20, to: 60)
        recorder.setMuted(false, lastSeenMuted: t0.addingTimeInterval(59))
        speak(from: 60, to: 90)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [MuteSpan(start: 20, end: 59)])
        XCTAssertEqual(try loudest(id, from: 20.1, to: 58.9), 0)
        XCTAssertGreaterThan(try loudest(id, from: 59.1, to: 60), 0.3)
    }

    /// The owner changed to another tab while muted, so the mute state was unknown; the owner unmuted and spoke.
    /// The detector reports "unmuted" 10 s later. Those 10 s nobody watched are kept, not silenced.
    func testTheUnknownTimeBeforeAnUnmuteReportIsKept() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 20)
        recorder.setMuted(true)
        speak(from: 20, to: 50)
        recorder.setMuted(false, lastSeenMuted: t0.addingTimeInterval(40))
        speak(from: 50, to: 90)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [MuteSpan(start: 20, end: 40)])
        XCTAssertEqual(try loudest(id, from: 20.1, to: 39.9), 0)
        XCTAssertGreaterThan(try loudest(id, from: 40.1, to: 50), 0.3, "the 10 s of the unknown window are in the track")
        XCTAssertFalse(r.mutedAudioPending)
    }

    /// The pause is not in the file, so the last sighting is converted to file time.
    func testAMuteSpanEndIsInFileTimeAfterAPause() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 30)
        recorder.pause()
        now = t0.addingTimeInterval(630)
        recorder.resume()
        speak(from: 630, to: 650)   // file 30...50
        recorder.setMuted(true)
        speak(from: 650, to: 680)   // file 50...80
        recorder.setMuted(false, lastSeenMuted: t0.addingTimeInterval(675))
        speak(from: 680, to: 720)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [MuteSpan(start: 50, end: 75)])
    }

    // MARK: A silence pass that fails

    /// A full disk: the muted parts cannot be silenced. The audio is kept, but the call must not reach the
    /// pipeline as "recorded", or what was said while muted goes to the transcription provider.
    func testACallWhoseMutedPartsCannotBeSilencedIsHeldBack() throws {
        silenceFails = true
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 20)
        recorder.setMuted(true)
        XCTAssertTrue(try CallRecord.load(from: paths.callDirectory(id)).mutedAudioPending, "saved when the span opens, for a crash")
        speak(from: 20, to: 60)
        recorder.setMuted(false, lastSeenMuted: now)
        speak(from: 60, to: 90)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.failedStep, .recorded)
        XCTAssertEqual(r.failureReason, MutedAudio.failureReason)
        XCTAssertTrue(r.mutedAudioPending)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)), r)
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("me.caf")), 90, accuracy: 0.1, "the audio is kept")
        XCTAssertEqual(problems, [.mutedNotSilenced], "the owner is told once")
        XCTAssertTrue(ProcessingQueue(paths: paths).pending(now: now.addingTimeInterval(86_400)).isEmpty)
    }

    func testACallWithNoMuteIsNotPending() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 70)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.status, .recorded)
        XCTAssertFalse(r.mutedAudioPending)
    }

    func testAMuteSpanIsSavedWhenItOpensAndTheTrackKeepsTheSamplesUntilTheEnd() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 30)
        recorder.setMuted(true)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).muteSpans, [MuteSpan(start: 30, end: nil)])
        speak(from: 30, to: 90)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [MuteSpan(start: 30, end: 90)])
        XCTAssertGreaterThan(try loudest(id, from: 1, to: 29.9), 0.3)
        XCTAssertEqual(try loudest(id, from: 30.1, to: 90), 0, "still muted at the end: silence to the end")
        XCTAssertTrue(r.markers.contains { $0.text.hasSuffix("to the end of the recording") })
    }

    func testAMuteShorterThanTheUnknownTimeSilencesNothing() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 30)
        recorder.setMuted(true)
        speak(from: 30, to: 32)
        recorder.setMuted(false)
        speak(from: 32, to: 70)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [])
        XCTAssertEqual(r.markers.filter { $0.text.hasPrefix("Muted from ") }.count, 1)
    }

    /// A mute belongs to its call. Carried into a new call whose mute button cannot be read, it stayed open and
    /// silenced that call's whole mic track.
    func testANewCallStartsUnmuted() throws {
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        now = t0.addingTimeInterval(100)
        recorder.setMuted(true)
        now = t0.addingTimeInterval(300)
        let second = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [2], at: now)
        XCTAssertFalse(recorder.isMuted)
        speak(from: 300, to: 400)
        let r = try XCTUnwrap(recorder.end(at: now, trimTo: nil))
        XCTAssertEqual(r.muteSpans, [])
        XCTAssertGreaterThan(try loudest(second, from: 1, to: 99), 0.3)
    }

    // MARK: Sources that fail quietly

    /// The tap had no stall check: after AirPods changed their rate, or a wake from sleep, the call track stayed
    /// silent to the end of the call.
    func testATapThatSendsNoAudioIsRebuilt() throws {
        me.seconds = 1
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        now = t0.addingTimeInterval(CallRecorder.stallLimit + 1)
        me.send(1)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(themMade, [[5], [5]])
        XCTAssertEqual(me.startCalls, 1)
    }

    func testATapThatSendsAudioIsLeftAlone() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        for second in 1...30 {
            now = t0.addingTimeInterval(Double(second))
            them.send(1, amplitude: 0)   // a quiet call still sends buffers
            me.send(1)
            recorder.updateThemProcesses([5])
        }
        XCTAssertEqual(themMade, [[5]])
        XCTAssertEqual(problems, [])
    }

    func testATapThatStaysSilentIsToldOnceAndThenTriedLessOften() throws {
        _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        for second in 1...100 {
            now = t0.addingTimeInterval(Double(second))
            me.send(1)
            recorder.updateThemProcesses([5])
        }
        XCTAssertEqual(problems, [.callAudioNotRecording])
        // Three restarts 11 s apart, then one a minute.
        XCTAssertEqual(themMade.count, 5)
    }

    func testAMicThatStaysSilentIsTold() throws {
        _ = try recorder.beginManual(at: t0)
        for second in 1...60 {
            now = t0.addingTimeInterval(Double(second))
            recorder.checkMic()
        }
        XCTAssertEqual(problems, [.micNotRecording])
        XCTAssertEqual(me.startCalls, 4)
    }

    func testMissingPermissionsAreToldWhenTheCallStarts() throws {
        let recorder = makeRecorder(systemAudioAllowed: { false }, micAllowed: { false })
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        XCTAssertEqual(problems, [.micDenied, .systemAudioDenied])
        now = t0.addingTimeInterval(60)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(problems.count, 2, "each problem is told once per call")
    }

    func testALowDiskIsToldWhenTheCallStarts() throws {
        let recorder = makeRecorder(freeBytes: { 200_000_000 })
        _ = try recorder.beginManual(at: t0)
        XCTAssertEqual(problems, [.diskLow])
    }

    func testAMicThatCannotStartIsToldAfterTheGrace() throws {
        me.failStarts = 100
        _ = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [5], at: t0)
        XCTAssertEqual(problems, [])
        now = t0.addingTimeInterval(CaptureHealth.grace)
        them.send(1)
        recorder.updateThemProcesses([5])
        XCTAssertEqual(problems, [.micNotRecording])
    }

    // MARK: All system audio

    private func tap(global: Bool, failStarts: Int = 0) -> FakeSource {
        let source = FakeSource()
        source.isGlobal = global
        source.failStarts = failStarts
        return source
    }

    /// A tap that fell back to all system audio stayed for the call: music went to the transcript as "them".
    /// It is marked in the transcript, and the call app's own audio is tried again. A try never stops the tap that
    /// works: stopping it each 30 s cut a hole in the call track each time.
    func testATryForTheCallAppsOwnAudioNeverStopsTheTapThatWorks() throws {
        let global = tap(global: true), stillGlobal = tap(global: true), failing = tap(global: false, failStarts: 1)
        taps = [global, stillGlobal, failing]
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        for second in 1...100 {
            now = t0.addingTimeInterval(Double(second))
            global.send(1)
            me.send(1)
            recorder.updateThemProcesses([5])
        }
        XCTAssertEqual(themMade.count, 3, "tried after 30 s, then after 60 s more: the wait doubles")
        XCTAssertFalse(global.stopped, "the tap that works was never stopped")
        XCTAssertTrue(stillGlobal.stopped && failing.stopped)
        XCTAssertEqual(try CallRecord.load(from: paths.callDirectory(id)).markers.map { String($0.text.prefix(30)) }, ["The call audio includes every "])
        _ = recorder.end(at: now, trimTo: nil)
        let samples = try AudioSamples.read(paths.callDirectory(id).appendingPathComponent("them.caf"), from: 0, to: 100)
        XCTAssertEqual(samples.count, 1_600_000, accuracy: 1_600)
        let silent = stride(from: 0, to: samples.count - 160, by: 160).filter { i in samples[i..<(i + 160)].allSatisfy { $0 == 0 } }.count
        XCTAssertEqual(silent, 0, "no hole in the call track")
    }

    func testTheSwitchToTheCallAppsOwnAudioLosesNoAudioAndWritesTheOverlapOnce() throws {
        let global = tap(global: true), own = tap(global: false)
        taps = [global, own]
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [5], at: t0)
        for second in 1...29 {
            now = t0.addingTimeInterval(Double(second))
            global.send(1)
            recorder.updateThemProcesses([5])
        }
        // The new tap starts and already has half a second that the old tap also sends before it stops.
        now = t0.addingTimeInterval(30)
        own.seconds = 0.5
        global.send(1)
        recorder.updateThemProcesses([5])
        XCTAssertTrue(own.started)
        XCTAssertTrue(global.stopped, "stopped only after the new tap ran")
        for second in 31...70 {
            now = t0.addingTimeInterval(Double(second))
            own.send(1)
            recorder.updateThemProcesses([5])
        }
        XCTAssertEqual(themMade.count, 2)
        _ = recorder.end(at: now, trimTo: nil)
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("them.caf")), 70, accuracy: 0.05, "the overlap is in the track once")
        XCTAssertGreaterThan(try loudest(id, .them, from: 29, to: 32), 0.3)
    }

    // MARK: IDs, pauses, quit

    /// Two starts in the same local second (the hour that repeats when daylight time ends) destroyed the first call.
    func testACallWithTheIDOfAnOlderCallGetsItsOwnFolder() throws {
        let old = CallRecorder.callID(for: t0)
        let dir = paths.callDirectory(old)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try CallRecord(id: old, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0.addingTimeInterval(600), status: .written).save(to: dir)
        try writeTestAudio(dir.appendingPathComponent("me.caf"), seconds: 5, frequency: 440)
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        XCTAssertEqual(id, old + "-2")
        recorder.skip()
        XCTAssertEqual(try CallRecord.load(from: dir).status, .written)
        XCTAssertEqual(try audioDuration(dir.appendingPathComponent("me.caf")), 5, accuracy: 0.01)
    }

    /// After a pause the files are shorter than the wall time. The end logic added file seconds to the start date,
    /// so sound after the pause looked 10 minutes older than it was and was cut.
    func testAFallbackEndAfterAPauseKeepsTheLastSound() throws {
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        speak(from: 0, to: 60)
        recorder.pause()
        now = t0.addingTimeInterval(660)
        recorder.resume()
        speak(from: 660, to: 760)   // 100 s more: the files hold 160 s
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(900), trimTo: t0.addingTimeInterval(700)))
        XCTAssertEqual(r.end.timeIntervalSince(t0), 761, accuracy: 1, "the wall time of the last sound, plus a second")
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("me.caf")), 160, accuracy: 0.1)
    }

    func testAFallbackEndAfterAPauseTrimsInFileTime() throws {
        let id = try recorder.begin(platform: .zoom, bundleID: "us.zoom.xos", processIDs: [1], at: t0)
        speak(from: 0, to: 60)
        recorder.pause()
        now = t0.addingTimeInterval(660)
        recorder.resume()
        for second in 660..<760 {
            now = t0.addingTimeInterval(Double(second + 1))
            me.send(1, amplitude: 0)
        }
        let r = try XCTUnwrap(recorder.end(at: t0.addingTimeInterval(900), trimTo: t0.addingTimeInterval(700)))
        XCTAssertEqual(r.end.timeIntervalSince(t0), 700, accuracy: 0.01)
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("me.caf")), 100, accuracy: 0.1, "60 s before the pause and 40 s after it")
    }

    /// Audio that reached the feed before a pause belongs in the file, and nothing is written for the paused time.
    func testPauseKeepsWhatWasSentAndLeavesThePausedTimeOut() throws {
        let id = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: t0)
        speak(from: 0, to: 30)
        recorder.pause()
        XCTAssertEqual(recorder.meDuration, 30, accuracy: 0.05)
        now = t0.addingTimeInterval(300)
        recorder.resume()
        speak(from: 300, to: 340)
        XCTAssertEqual(recorder.meDuration, 70, accuracy: 0.05)
        _ = recorder.end(at: now, trimTo: nil)
        XCTAssertEqual(try audioDuration(paths.callDirectory(id).appendingPathComponent("me.caf")), 70, accuracy: 0.1)
    }

    /// The app reads the durations on the main thread while the capture queue starts and ends calls.
    func testDurationsCanBeReadFromAnotherThreadWhileCallsStartAndEnd() throws {
        let reader = DispatchQueue(label: "reader")
        let recorder = recorder
        let stop = Counter()
        reader.async { while stop.value == 0 { _ = recorder.meDuration + recorder.themDuration } }
        for i in 0..<20 {
            now = t0.addingTimeInterval(Double(i) * 100)
            _ = try recorder.begin(platform: .meet, bundleID: "com.google.Chrome", processIDs: [1], at: now)
            recorder.skip()
        }
        stop.add(1)
        reader.sync {}
    }
}
