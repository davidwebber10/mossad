import XCTest
import CoreAudio
@testable import MossadCore

final class FakeMic: MicUsageProbing {
    var list: [AudioProcess] = []
    /// The list itself cannot be read.
    var unreadable = false
    var callActiveSeen: [Bool] = []
    func processes() -> [AudioProcess] { list }
    func scan(callActive: Bool) -> [AudioProcess]? {
        callActiveSeen.append(callActive)
        return unreadable ? nil : list
    }
}

final class FakeTabs: BrowserTabProbing {
    var tabs: [String: [BrowserTab]] = [:]
    var queried: [String] = []
    var unreadable: Set<String> = []
    var denied: Set<String> = []
    func tabs(browserBundleID: String) -> [BrowserTab]? {
        queried.append(browserBundleID)
        if unreadable.contains(browserBundleID) || denied.contains(browserBundleID) { return nil }
        return tabs[browserBundleID] ?? []
    }
    func automationDenied(browserBundleID: String) -> Bool { denied.contains(browserBundleID) }
}

final class FakeMute: MuteProbing {
    var labels: [String]? = nil
    var calls = 0
    var lastMeetingID: String?
    func labels(bundleID: String, platform: Platform, meetingID: String?) -> [String]? {
        calls += 1
        lastMeetingID = meetingID
        return labels
    }
}

final class FakeWindows: WindowTitleProbing {
    var titles: [String: [String]] = [:]
    /// The titles of the copies that answered, when another copy did not (so `titles` is unknown).
    var answered: [String: [String]] = [:]
    var running: Set<String> = []
    func windowTitles(bundleID: String) -> [String]? { titles[bundleID] }
    func answeredWindowTitles(bundleID: String) -> [String]? { answered[bundleID] ?? titles[bundleID] }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}

final class ChangeBox: @unchecked Sendable {
    var changes: [Bool] = []
}

final class DetectionServiceTests: XCTestCase {
    let mic = FakeMic()
    let tabs = FakeTabs()
    let windows = FakeWindows()
    lazy var service = DetectionService(mic: mic, tabs: tabs, windows: windows)
    let now = Date(timeIntervalSince1970: 2_000_000)

    func proc(_ id: AudioObjectID, _ bundle: String, input: Bool?, output: Bool? = true) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid_t(id), bundleID: bundle, isRunningInput: input, isRunningOutput: output)
    }

    /// Unknown is not false: a mic state that cannot be read keeps a Meet call, which a released mic ends in 6 s.
    func testAMicStateThatCannotBeReadDoesNotEndTheCall() {
        let chrome = "com.google.Chrome"
        tabs.tabs[chrome] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        mic.list = [proc(1, chrome, input: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events.count, 1)
        mic.list = [proc(1, chrome, input: nil, output: nil)]
        for i in 1...10 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1, "the call must go on while the mic state is unknown")
        mic.unreadable = true
        for i in 11...20 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1, "the call must go on while the list is unknown")
        mic.unreadable = false
        mic.list = [proc(1, chrome, input: false)]
        for i in 21...26 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 2, "a known released mic ends the call")
    }

    func testAnUnknownMicStateNeverStartsACall() {
        let chrome = "com.google.Chrome"
        tabs.tabs[chrome] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        mic.list = [proc(1, chrome, input: nil)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertTrue(events.isEmpty)
    }

    func testTheScanLearnsWhetherACallRuns() {
        let chrome = "com.google.Chrome"
        tabs.tabs[chrome] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        mic.list = [proc(1, chrome, input: true)]
        service.tick(at: now)
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(mic.callActiveSeen, [false, true])
    }

    func testOneProcessThatRunsWinsOverOneThatIsUnknown() {
        XCTAssertEqual(DetectionService.anyRunning([nil, true]), true)
        XCTAssertNil(DetectionService.anyRunning([false, nil]))
        XCTAssertEqual(DetectionService.anyRunning([false, false]), false)
        XCTAssertEqual(DetectionService.anyRunning([]), false)
    }

    // MARK: Tab reads outside a call

    private func dictationInChrome() -> String {
        let chrome = "com.google.Chrome"
        tabs.tabs[chrome] = [BrowserTab(url: "https://example.com/notes", title: "Notes", isActive: true)]
        windows.titles[chrome] = ["Notes"]
        mic.list = [proc(1, chrome, input: true)]
        return chrome
    }

    /// A browser that used the mic for dictation was asked for its tabs every 2 s for as long as that lasted.
    func testANoMeetingAnswerOutsideACallHoldsForTenSeconds() {
        let chrome = dictationInChrome()
        for i in 0..<5 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(tabs.queried, [chrome], "one read for the ticks at 0, 2, 4, 6, and 8 s")
        service.tick(at: now.addingTimeInterval(10))
        XCTAssertEqual(tabs.queried.count, 2)
    }

    func testTheTabsAreReadAgainAtOnceWhenTheMicStopsAndStarts() {
        let chrome = dictationInChrome()
        service.tick(at: now)
        mic.list = [proc(1, chrome, input: false)]
        service.tick(at: now.addingTimeInterval(2))
        mic.list = [proc(1, chrome, input: true)]
        service.tick(at: now.addingTimeInterval(4))
        XCTAssertEqual(tabs.queried.count, 2)
    }

    /// The owner joins a call in the browser that already used the mic: the window title changes, so the next
    /// tick reads the tabs and the call starts with no wait.
    func testACallThatStartsDuringOtherMicUseIsSeenAtTheNextTick() {
        let chrome = dictationInChrome()
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        tabs.tabs[chrome] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        windows.titles[chrome] = ["Meet - abc-defg-hij"]
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(events, [.started(platform: .meet, bundleID: chrome, at: now.addingTimeInterval(2))])
    }

    func testAnUnreadableAnswerIsNotHeld() {
        let chrome = dictationInChrome()
        tabs.unreadable = [chrome]
        service.tick(at: now)
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(tabs.queried.count, 2, "unknown is asked again; the probe has its own backoff")
    }

    func testAfterACallTheTabsAreReadAgainAtOnce() {
        let chrome = dictationInChrome()
        service.tick(at: now)
        service.reset()
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(tabs.queried.count, 2)
    }

    /// An in-person recording owns the mic, so the tick skips the Core Audio scan it would throw away.
    func testASuspendedServiceDoesNotScan() {
        final class CountingMic: MicUsageProbing { var calls = 0; func processes() -> [AudioProcess] { calls += 1; return [] } }
        let counting = CountingMic()
        let s = DetectionService(mic: counting, tabs: tabs, windows: windows)
        s.isSuspended = true
        s.tick(at: now)
        XCTAssertEqual(counting.calls, 0)
        s.isSuspended = false
        s.tick(at: now)
        XCTAssertEqual(counting.calls, 1)
    }

    /// The Teams app's window titles do not say whether a meeting is open, but its meeting controls do: the mute
    /// button is there for the whole call and gone when you leave. A call used to run on for 3 minutes after it ended.
    func testTheTeamsAppCallEndsWhenItsMeetingControlsGo() {
        let mute = FakeMute()
        let s = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        let teams = "com.microsoft.teams2"
        windows.titles[teams] = ["Weekly sync | Dana Lee"]
        windows.running = [teams]
        mic.list = [proc(4, teams, input: true)]
        mute.labels = ["Mute mic", "Myself video, Dana Lee, Unmuted"]
        var events: [DetectorEvent] = []
        s.onEvent = { events.append($0) }
        s.tick(at: now)
        XCTAssertEqual(s.snapshot(at: now).candidates.first?.meetingPresent, true)
        s.tick(at: now.addingTimeInterval(1))
        // You left: the mic is released and the controls are gone.
        mic.list = [proc(4, teams, input: false)]
        mute.labels = []
        windows.titles[teams] = []
        s.tick(at: now.addingTimeInterval(2))
        s.tick(at: now.addingTimeInterval(4))
        XCTAssertEqual(events.count, 2)
        if case .ended = events.last {} else { XCTFail("the call should have ended") }
    }

    /// Muted with the mic released, the controls are still there: still in the call.
    func testATeamsCallWithItsControlsStaysOpenWhileTheMicIsIdle() {
        let mute = FakeMute()
        let s = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        let teams = "com.microsoft.teams2"
        windows.running = [teams]
        mic.list = [proc(4, teams, input: true)]
        mute.labels = ["Unmute mic"]
        var events: [DetectorEvent] = []
        s.onEvent = { events.append($0) }
        s.tick(at: now)
        mic.list = [proc(4, teams, input: false)]
        for i in 1...150 { s.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
    }

    func testSnapshotGroupsBrowserHelpersUnderBaseBrowser() {
        mic.list = [proc(1, "com.google.Chrome", input: false), proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        let s = service.snapshot(at: now)
        XCTAssertEqual(s.candidates, [MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: true, meetingPresent: true, outputActive: true)])
    }

    func testStartedCallKeepsTheMeetingIDOfTheActiveTab() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [
            BrowserTab(url: "https://meet.google.com/xyz-wxyz-xyz", title: "Meet - xyz-wxyz-xyz"),
            BrowserTab(url: "https://meet.google.com/meet/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true),
        ]
        service.tick(at: now)
        XCTAssertEqual(service.meetingID, "abc-defg-hij")
    }

    func testMuteChangesAreReportedDuringACall() {
        let mute = FakeMute()
        let service = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        var changes: [Bool] = []
        service.onMuteChange = { changes.append($0) }
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        mute.labels = ["Turn off microphone"]
        service.tick(at: now)
        service.checkMute(at: now)
        XCTAssertEqual(mute.lastMeetingID, "abc-defg-hij", "the probe reads the window of this call")
        mute.labels = ["Turn on microphone"]
        service.checkMute(at: now.addingTimeInterval(4))
        service.checkMute(at: now.addingTimeInterval(8))
        mute.labels = ["Leave call"]  // unknown for a moment: no change
        service.checkMute(at: now.addingTimeInterval(9))
        mute.labels = ["Turn off microphone"]
        service.checkMute(at: now.addingTimeInterval(10))
        XCTAssertEqual(changes, [false, true, false])
    }

    func testNoMuteChecksOutsideACall() {
        let mute = FakeMute()
        let service = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        service.tick(at: now)
        service.checkMute(at: now)
        XCTAssertEqual(mute.calls, 0)
    }

    private func meetCall(_ mute: FakeMute) -> (DetectionService, () -> [Bool]) {
        let service = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        let box = ChangeBox()
        service.onMuteChange = { box.changes.append($0) }
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        service.tick(at: now)
        return (service, { box.changes })
    }

    /// While muted the state is read each second, so an unmute is seen within about a second, not four.
    func testWhileMutedTheStateIsReadEachSecond() {
        let mute = FakeMute()
        let (service, _) = meetCall(mute)
        mute.labels = ["Turn on microphone"]
        service.checkMute(at: now)
        mute.calls = 0
        for s in 1...6 { service.checkMute(at: now.addingTimeInterval(Double(s))) }
        XCTAssertEqual(mute.calls, 6)
        mute.labels = ["Turn off microphone"]
        service.checkMute(at: now.addingTimeInterval(7))
        mute.calls = 0
        for s in 8...13 { service.checkMute(at: now.addingTimeInterval(Double(s))) }
        XCTAssertEqual(mute.calls, 2, "unmuted, every 3 s is enough")
    }

    /// The owner muted, then selected another tab and unmuted from a headset: the state turned unknown and the
    /// mic stayed muted for the rest of the call. Unknown for more than 10 s now means unmuted.
    func testMutedThatTurnsUnknownBecomesUnmuted() {
        let mute = FakeMute()
        let (service, changes) = meetCall(mute)
        var times: [Date?] = []
        service.onMuteChangeAt = { _, seen in times.append(seen) }
        mute.labels = ["Turn on microphone"]
        service.checkMute(at: now)
        service.checkMute(at: now.addingTimeInterval(1))
        mute.labels = nil
        for s in 2...11 { service.checkMute(at: now.addingTimeInterval(Double(s))) }
        XCTAssertEqual(changes(), [true])
        service.checkMute(at: now.addingTimeInterval(12))
        XCTAssertEqual(changes(), [true, false])
        XCTAssertEqual(service.lastMutedSeen, now.addingTimeInterval(1))
        XCTAssertEqual(times, [now, now.addingTimeInterval(1)], "each change carries the last reading that saw muted")
        // Unknown after unmuted changes nothing.
        for s in 13...40 { service.checkMute(at: now.addingTimeInterval(Double(s))) }
        XCTAssertEqual(changes(), [true, false])
    }

    /// A new call starts with no mute state from the call before.
    func testEachCallStartsWithItsOwnMuteState() {
        let mute = FakeMute()
        let (service, changes) = meetCall(mute)
        mute.labels = ["Turn on microphone"]
        service.checkMute(at: now)
        mic.list = []
        service.tick(at: now.addingTimeInterval(2))
        service.tick(at: now.addingTimeInterval(4))
        service.tick(at: now.addingTimeInterval(10))
        service.checkMute(at: now.addingTimeInterval(11))
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        service.tick(at: now.addingTimeInterval(20))
        service.checkMute(at: now.addingTimeInterval(21))
        XCTAssertEqual(changes(), [true, true])
    }

    func testDuringACallTheTabsAreReadAtMostEveryTenSeconds() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        service.tick(at: now)
        tabs.queried = []
        for s in stride(from: 2.0, through: 18, by: 2) { service.tick(at: now.addingTimeInterval(s)) }
        // Ticks at 2..18 s: reads at 10 s and 20 s at the earliest, so only one in this window.
        XCTAssertEqual(tabs.queried.count, 1)
    }

    /// Without readable window titles there is no proof that the tabs are the same, so nothing is held.
    func testBeforeACallTheTabsAreReadOnEveryTickWhenTheWindowTitlesAreUnknown() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://www.youtube.com/watch?v=x", title: "YouTube", isActive: true)]
        for s in stride(from: 0.0, through: 8, by: 2) { service.tick(at: now.addingTimeInterval(s)) }
        XCTAssertEqual(tabs.queried.count, 5)
    }

    func testBrowserMicWithoutMeetingTabHasNoCandidate() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://www.youtube.com/watch?v=x", title: "YouTube")]
        XCTAssertTrue(service.snapshot(at: now).candidates.isEmpty)
    }

    func testZoomCandidateFromWindowTitles() {
        mic.list = [proc(3, "us.zoom.xos", input: true)]
        windows.titles["us.zoom.xos"] = ["Zoom Workplace", "Zoom Meeting"]
        XCTAssertEqual(service.snapshot(at: now).candidates.first?.meetingPresent, true)
        windows.titles["us.zoom.xos"] = ["Zoom Workplace"]
        XCTAssertEqual(service.snapshot(at: now).candidates.first?.meetingPresent, false)
        windows.titles["us.zoom.xos"] = nil
        XCTAssertNil(service.snapshot(at: now).candidates.first?.meetingPresent)
    }

    func testTeamsUnmatchedTitleIsUnknown() {
        mic.list = [proc(4, "com.microsoft.teams2", input: true)]
        windows.titles["com.microsoft.teams2"] = ["Chat | Microsoft Teams"]
        XCTAssertEqual(service.snapshot(at: now).candidates, [MeetingCandidate(platform: .teams, bundleID: "com.microsoft.teams2", micActive: true, meetingPresent: nil, outputActive: true)])
    }

    func testBrowserTabsNotQueriedWithoutMicOrCall() {
        mic.list = [proc(1, "com.google.Chrome", input: false), proc(5, "com.apple.Safari", input: false)]
        _ = service.snapshot(at: now)
        XCTAssertEqual(tabs.queried, [])
    }

    func testCurrentCallAppStaysCandidateWithoutMic() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events.count, 1)
        mic.list = [proc(2, "com.google.Chrome.helper", input: false)]
        XCTAssertEqual(service.snapshot(at: now).candidates, [MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: false, meetingPresent: true, outputActive: true)])
    }

    func testMeetPostCallPageIsGone() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        service.tick(at: now)
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet")]
        // During a call the tabs are read again after `tabRefreshDuringCall`.
        XCTAssertEqual(service.snapshot(at: now.addingTimeInterval(DetectionService.tabRefreshDuringCall)).candidates.first?.meetingPresent, false)
    }

    func testAudioProcessIDsForCurrentCall() {
        mic.list = [proc(1, "com.google.Chrome", input: false), proc(2, "com.google.Chrome.helper", input: true), proc(3, "us.zoom.xos", input: false)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        XCTAssertEqual(service.audioProcessIDs, [])
        service.tick(at: now)
        XCTAssertEqual(service.audioProcessIDs, [1, 2])
    }

    func testReportsCallProcessesEachTick() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        var reports: [[AudioObjectID]] = []
        service.onCallProcesses = { reports.append($0) }
        service.tick(at: now)
        mic.list = [proc(2, "com.google.Chrome.helper", input: true), proc(7, "com.google.Chrome.helper", input: false)]
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(reports, [[2], [2, 7]])
    }

    func testBackgroundMeetingTabDoesNotStartACall() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [
            BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Chat | Microsoft Teams", isActive: false),
            BrowserTab(url: "https://docs.google.com/document/d/1", title: "Notes", isActive: true),
        ]
        XCTAssertTrue(service.snapshot(at: now).candidates.isEmpty)
        tabs.tabs["com.google.Chrome"]![0].isActive = true
        XCTAssertEqual(service.snapshot(at: now).candidates.first?.platform, .teams)
    }

    func testBackgroundMeetingTabKeepsACallGoing() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        service.tick(at: now)
        tabs.tabs["com.google.Chrome"]![0].isActive = false
        XCTAssertEqual(service.snapshot(at: now).candidates.first?.meetingPresent, true)
    }

    func testCallAppMissingFromAudioListButRunningIsUnknown() {
        mic.list = [proc(3, "us.zoom.xos", input: true)]
        windows.titles["us.zoom.xos"] = ["Zoom Meeting"]
        windows.running = ["us.zoom.xos"]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        mic.list = []
        service.tick(at: now.addingTimeInterval(2))
        service.tick(at: now.addingTimeInterval(4))
        service.tick(at: now.addingTimeInterval(6))
        XCTAssertEqual(events.count, 1, "an audio reset must not end the call while the app runs")
        windows.running = []
        service.tick(at: now.addingTimeInterval(8))
        service.tick(at: now.addingTimeInterval(10))
        XCTAssertEqual(events.count, 2)
    }

    // MARK: Calls Mossad cannot confirm

    /// A second copy of Chrome (a test tool's) made the tab list unknown, and the owner's Meet call went unrecorded
    /// without a word. The window titles of every copy still show the Meet window, so the call starts.
    func testAnUnreadableTabListFallsBackToTheMeetWindowTitle() {
        let chrome = "com.google.Chrome"
        tabs.unreadable = [chrome]
        windows.titles[chrome] = ["Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)"]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events, [.started(platform: .meet, bundleID: chrome, at: now)])
    }

    func testAnUnreadableTabListWithTheMicOnWarnsAfterTenSeconds() {
        let chrome = "com.google.Chrome"
        tabs.unreadable = [chrome]
        windows.titles[chrome] = ["Inbox - Google Chrome"]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var warnings: [UnconfirmedCall] = []
        service.onUnconfirmed = { warnings.append($0) }
        for i in 0...6 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(warnings, [UnconfirmedCall(bundleID: chrome, platform: nil, reason: .cannotSeeMeeting)])
    }

    func testAMeetingTabInTheBackgroundWarns() {
        let chrome = "com.google.Chrome"
        tabs.tabs[chrome] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: false),
                             BrowserTab(url: "https://docs.google.com/x", title: "Doc", isActive: true)]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var warnings: [UnconfirmedCall] = []
        service.onUnconfirmed = { warnings.append($0) }
        for i in 0...6 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(warnings, [UnconfirmedCall(bundleID: chrome, platform: .meet, reason: .meetingTabNotSelected)])
    }

    /// Dictation or a voice note in a browser with no meeting tab is not a call, and says nothing.
    func testAKnownTabListWithNoMeetingDoesNotWarn() {
        let chrome = "com.google.Chrome"
        tabs.tabs[chrome] = [BrowserTab(url: "https://docs.google.com/x", title: "Doc", isActive: true)]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var warnings: [UnconfirmedCall] = []
        service.onUnconfirmed = { warnings.append($0) }
        for i in 0...10 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(warnings, [])
    }

    func testRecordOnTheWarningStartsTheCall() {
        let chrome = "com.google.Chrome"
        tabs.unreadable = [chrome]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        service.forceStartNow(bundleID: chrome, platform: .meet, at: now.addingTimeInterval(1))
        XCTAssertEqual(events, [.started(platform: .meet, bundleID: chrome, at: now.addingTimeInterval(1))])
        service.tick(at: now.addingTimeInterval(3))
        XCTAssertEqual(events.count, 1)
    }

    /// A call that Mossad sees but keeps off the record (the do-not-record list): Record on the notice sends its
    /// start again as the owner's choice, and the call still ends like a detected call.
    func testRecordOnABlockedCallSendsItsStartAgainAsTheOwnersChoice() {
        let chrome = "com.google.Chrome"
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs[chrome] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        var events: [DetectorEvent] = []
        var forced: [Bool] = []
        service.onEvent = { [unowned service] in events.append($0); forced.append(service.callIsForced) }
        service.tick(at: now)
        XCTAssertEqual(events, [.started(platform: .meet, bundleID: chrome, at: now)])
        service.recordBlockedCallNow(bundleID: chrome, platform: .meet, at: now.addingTimeInterval(5))
        XCTAssertEqual(events.last, .started(platform: .meet, bundleID: chrome, at: now.addingTimeInterval(5)))
        XCTAssertEqual(forced, [false, true])
        service.tick(at: now.addingTimeInterval(6))
        XCTAssertEqual(events.count, 2, "no third start")
    }

    /// The owner was muted in a call that was kept off the record, then pressed Record: the recorder starts
    /// unmuted, so the mute state must be reported again, or muted speech goes into the transcript.
    func testRecordOnABlockedCallReportsTheMuteStateAgain() {
        let mute = FakeMute()
        let (service, changes) = meetCall(mute)
        mute.labels = ["Turn on microphone"]
        service.checkMute(at: now.addingTimeInterval(1))
        XCTAssertEqual(changes(), [true])
        service.recordBlockedCallNow(bundleID: "com.google.Chrome", platform: .meet, at: now.addingTimeInterval(5))
        service.checkMute(at: now.addingTimeInterval(6))
        XCTAssertEqual(changes(), [true, true])
    }

    // MARK: Review findings

    /// Mossad was turned off during a call and on again: the detector still held the old call, so nothing recorded.
    func testAfterAResetACallThatIsStillOpenStartsAgain() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(events.count, 1)
        service.reset()
        XCTAssertNil(service.meetingID)
        XCTAssertEqual(service.audioProcessIDs, [])
        service.tick(at: now.addingTimeInterval(900))
        XCTAssertEqual(events, [.started(platform: .meet, bundleID: "com.google.Chrome", at: now),
                                .started(platform: .meet, bundleID: "com.google.Chrome", at: now.addingTimeInterval(900))])
    }

    /// Teams in another language: no label ever matches, so an empty list says nothing about the call.
    func testATeamsCallWhoseControlsWereNeverSeenDoesNotEndByAnEmptyLabelList() {
        let mute = FakeMute()
        let s = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        let teams = "com.microsoft.teams2"
        windows.running = [teams]
        mic.list = [proc(4, teams, input: true)]
        mute.labels = []
        var events: [DetectorEvent] = []
        s.onEvent = { events.append($0) }
        s.tick(at: now)
        mic.list = [proc(4, teams, input: false)]
        for i in 1...10 { s.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1, "unknown is not gone")
    }

    /// A muted Zoom call releases the mic; the meeting window and the sound of the call keep it, also past 3 minutes,
    /// and start it when the owner joins muted.
    func testAMutedZoomCallGoesOnPastThreeMinutesAndStartsWithoutTheMic() {
        let zoom = "us.zoom.xos"
        windows.running = [zoom]
        windows.titles[zoom] = ["Zoom Workplace", "Zoom Meeting"]
        mic.list = [proc(3, zoom, input: false, output: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events, [.started(platform: .zoom, bundleID: zoom, at: now)], "joined muted: the window and the sound are enough")
        for i in 1...150 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
        windows.titles[zoom] = ["Zoom Workplace"]
        service.tick(at: now.addingTimeInterval(302))
        service.tick(at: now.addingTimeInterval(304))
        XCTAssertEqual(events.count, 2)
    }

    /// A waiting room has the meeting window's title, but Zoom plays nothing and holds no mic: no recording.
    func testAZoomMeetingWindowWithNoSoundAndNoMicDoesNotStartACall() {
        let zoom = "us.zoom.xos"
        windows.running = [zoom]
        windows.titles[zoom] = ["Zoom Meeting"]
        mic.list = [proc(3, zoom, input: false, output: false)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        for i in 0...100 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertTrue(events.isEmpty)
    }

    /// A meeting window that stays open after the call does not record the room without an end.
    func testAZoomWindowLeftOpenEndsTheCallAfterThreeQuietMinutes() {
        let zoom = "us.zoom.xos"
        windows.running = [zoom]
        windows.titles[zoom] = ["Zoom Meeting"]
        mic.list = [proc(3, zoom, input: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        mic.list = [proc(3, zoom, input: false, output: false)]
        for i in 1...89 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
        service.tick(at: now.addingTimeInterval(180))
        XCTAssertEqual(events.last, .ended(at: now.addingTimeInterval(180), trimTo: now))
        for i in 91...120 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 2, "the window alone starts nothing")
    }

    /// Zoom runs with no meeting and no audio: its windows are not read at all, nothing starts, and nothing warns.
    func testZoomRunningWithoutAMeetingIsQuiet() {
        final class CountingWindows: WindowTitleProbing {
            var reads = 0
            func windowTitles(bundleID: String) -> [String]? { reads += 1; return ["Zoom Workplace"] }
            func isRunning(bundleID: String) -> Bool { true }
        }
        let counting = CountingWindows()
        let s = DetectionService(mic: mic, tabs: tabs, windows: counting)
        mic.list = [proc(3, "us.zoom.xos", input: false, output: false)]
        var events: [DetectorEvent] = []
        var warnings: [UnconfirmedCall] = []
        s.onEvent = { events.append($0) }
        s.onUnconfirmed = { warnings.append($0) }
        for i in 0...10 { s.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(counting.reads, 0)
    }

    /// The owner joins a Teams app meeting muted: Teams holds no mic, but its call controls are there and the call
    /// plays. Without the mic the controls are read at most each 10 s.
    func testATeamsCallJoinedMutedStartsByItsControlsAndItsSound() {
        let mute = FakeMute()
        let s = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        let teams = "com.microsoft.teams2"
        windows.running = [teams]
        var events: [DetectorEvent] = []
        s.onEvent = { events.append($0) }
        // A notification sound with no call: the controls are not there.
        mic.list = [proc(4, teams, input: false, output: true)]
        mute.labels = ["Chat", "Calendar"]
        for i in 0...4 { s.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(mute.calls, 1, "one read in 10 s")
        // No sound: Teams is not asked at all.
        mic.list = [proc(4, teams, input: false, output: false)]
        mute.labels = ["Unmute mic"]
        for i in 5...12 { s.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(mute.calls, 1)
        mic.list = [proc(4, teams, input: false, output: true)]
        s.tick(at: now.addingTimeInterval(26))
        XCTAssertEqual(events, [.started(platform: .teams, bundleID: teams, at: now.addingTimeInterval(26))])
    }

    /// During a Teams call the mute check reads the controls each few seconds; the tick uses that reading and does
    /// not walk the app again.
    func testTheTickUsesTheMuteChecksFreshReadingOfTheTeamsControls() {
        let mute = FakeMute()
        let s = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        let teams = "com.microsoft.teams2"
        windows.running = [teams]
        mic.list = [proc(4, teams, input: true)]
        mute.labels = ["Mute mic"]
        s.tick(at: now)
        s.checkMute(at: now.addingTimeInterval(1))
        mute.calls = 0
        s.tick(at: now.addingTimeInterval(2))
        s.tick(at: now.addingTimeInterval(4))
        XCTAssertEqual(mute.calls, 0)
        XCTAssertEqual(s.snapshot(at: now.addingTimeInterval(4)).candidates.first?.meetingPresent, true)
        // An old reading is not used.
        s.tick(at: now.addingTimeInterval(20))
        XCTAssertEqual(mute.calls, 1)
    }

    /// A screen share (or Zoom in another language) shows no "Zoom Meeting" window while the mic is still on.
    func testAZoomCallWithTheMicOnDoesNotEndWhenItsWindowTitleChanges() {
        let zoom = "us.zoom.xos"
        windows.running = [zoom]
        windows.titles[zoom] = ["Zoom Meeting"]
        mic.list = [proc(3, zoom, input: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        windows.titles[zoom] = ["zoom share toolbar window", "zoom share statusbar window"]
        for i in 1...60 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
        // The owner left: the mic is released and no meeting window is there.
        mic.list = [proc(3, zoom, input: false)]
        service.tick(at: now.addingTimeInterval(122))
        service.tick(at: now.addingTimeInterval(124))
        XCTAssertEqual(events.count, 2)
    }

    /// Firefox holds the mic: Mossad cannot read its tabs, so it must say so and not stay silent.
    func testABrowserMossadCannotReadWarnsAndCanBeRecorded() {
        let firefox = "org.mozilla.firefox"
        mic.list = [proc(9, firefox, input: true)]
        var warnings: [UnconfirmedCall] = []
        var events: [DetectorEvent] = []
        service.onUnconfirmed = { warnings.append($0) }
        service.onEvent = { events.append($0) }
        for i in 0...6 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(warnings, [UnconfirmedCall(bundleID: firefox, platform: nil, reason: .cannotSeeMeeting)])
        XCTAssertTrue(tabs.queried.isEmpty)
        service.forceStartNow(bundleID: firefox, platform: .meet, at: now.addingTimeInterval(14))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(service.audioProcessIDs, [9])
        // The call goes on while the mic is on, and ends by the mic alone.
        service.tick(at: now.addingTimeInterval(16))
        mic.list = [proc(9, firefox, input: false)]
        service.tick(at: now.addingTimeInterval(18))
        XCTAssertEqual(events.count, 1)
        service.tick(at: now.addingTimeInterval(50))
        XCTAssertEqual(events.count, 2)
    }

    /// Record pressed in Notification Center long after the warning: the app no longer uses the mic.
    func testRecordOnAStaleWarningDoesNothing() {
        let chrome = "com.google.Chrome"
        tabs.unreadable = [chrome]
        mic.list = [proc(2, "com.google.Chrome.helper", input: false)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.forceStartNow(bundleID: chrome, platform: .meet, at: now)
        XCTAssertTrue(events.isEmpty)
    }

    /// A hidden second copy of the browser does not answer Accessibility; the copy that answers shows the call.
    func testTheMeetTitleFallbackNeedsOnlyOneCopyToAnswer() {
        let chrome = "com.google.Chrome"
        tabs.unreadable = [chrome]
        windows.answered[chrome] = ["Meet - fkq-xdfx-vbe - Google Chrome"]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events, [.started(platform: .meet, bundleID: chrome, at: now)])
    }

    func testDeniedAutomationIsItsOwnReason() {
        let chrome = "com.google.Chrome"
        tabs.denied = [chrome]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var warnings: [UnconfirmedCall] = []
        service.onUnconfirmed = { warnings.append($0) }
        for i in 0...6 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(warnings, [UnconfirmedCall(bundleID: chrome, platform: nil, reason: .noAutomation)])
    }

    /// One wrong "no meeting" tab list was used for five ticks from the cache, and ended a call alone.
    func testATabListWithoutTheCallIsReadAgainOnTheNextTick() {
        let chrome = "com.google.Chrome"
        let call = [BrowserTab(url: "https://zoom.us/wc/123456789/join", title: "Zoom", isActive: true)]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs[chrome] = call
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        mic.list = [proc(2, "com.google.Chrome.helper", input: false)]
        tabs.tabs[chrome] = []  // one wrong answer
        service.tick(at: now.addingTimeInterval(10))
        tabs.tabs[chrome] = call
        tabs.queried = []
        service.tick(at: now.addingTimeInterval(12))
        XCTAssertEqual(tabs.queried, [chrome])
        service.tick(at: now.addingTimeInterval(14))
        XCTAssertEqual(events.count, 1)
    }

    /// Teams web keeps the call when the owner opens Chat in the same tab, and the tab title changes: the call
    /// must not be cut in two.
    func testATeamsWebCallGoesOnWhenItsTabMovesToChat() {
        let chrome = "com.google.Chrome"
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs[chrome] = [BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Meeting with Dana Lee | Microsoft Teams", isActive: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        tabs.tabs[chrome] = [BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Chat | Microsoft Teams", isActive: true)]
        for i in 1...40 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        mic.list = [proc(2, "com.google.Chrome.helper", input: false)]
        for i in 41...60 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
    }

    /// The owner's Record on a warning is marked, so the no-record session does not stop it.
    func testAForcedCallIsMarkedAsForced() {
        let chrome = "com.google.Chrome"
        tabs.unreadable = [chrome]
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        var forced: [Bool] = []
        service.onEvent = { [unowned service] _ in forced.append(service.callIsForced) }
        service.forceStartNow(bundleID: chrome, platform: .meet, at: now)
        mic.list = []
        service.tick(at: now.addingTimeInterval(40))
        XCTAssertFalse(service.callIsForced)
        mic.list = [proc(3, "us.zoom.xos", input: true)]
        windows.titles["us.zoom.xos"] = ["Zoom Meeting"]
        service.tick(at: now.addingTimeInterval(42))
        XCTAssertEqual(forced, [true, false, false])
    }

    /// Another WebKit app records through the shared WebKit GPU process; with Safari closed that is not Safari.
    func testTheWebKitProcessWithoutSafariIsNotACall() {
        tabs.unreadable = ["com.apple.Safari"]
        mic.list = [proc(6, "com.apple.WebKit.GPU", input: true)]
        var warnings: [UnconfirmedCall] = []
        service.onUnconfirmed = { warnings.append($0) }
        for i in 0...6 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertTrue(warnings.isEmpty)
        windows.running = ["com.apple.Safari"]
        for i in 7...14 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(warnings.count, 1)
    }

    /// The recorder must know the call before its first mute change.
    func testTheMuteStateIsNotReadBeforeTheCallIsAnnounced() {
        let mute = FakeMute()
        mute.labels = ["Turn on microphone"]
        let s = DetectionService(mic: mic, tabs: tabs, windows: windows, mute: mute)
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        let box = ChangeBox()
        s.onMuteChange = { box.changes.append($0) }
        s.onEvent = { [now] _ in s.checkMute(at: now) }
        s.tick(at: now)
        XCTAssertEqual(box.changes, [])
        s.checkMute(at: now)
        XCTAssertEqual(box.changes, [true])
    }
}
