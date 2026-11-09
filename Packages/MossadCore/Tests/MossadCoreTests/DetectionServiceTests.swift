import XCTest
import CoreAudio
@testable import MossadCore

final class FakeMic: MicUsageProbing {
    var list: [AudioProcess] = []
    func processes() -> [AudioProcess] { list }
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

    func proc(_ id: AudioObjectID, _ bundle: String, input: Bool) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid_t(id), bundleID: bundle, isRunningInput: input, isRunningOutput: true)
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
        for i in 1...10 { s.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
    }

    func testSnapshotGroupsBrowserHelpersUnderBaseBrowser() {
        mic.list = [proc(1, "com.google.Chrome", input: false), proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij", isActive: true)]
        let s = service.snapshot(at: now)
        XCTAssertEqual(s.candidates, [MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: true, meetingPresent: true)])
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
        mute.labels = ["Turn on microphone"]
        service.checkMute(at: now)
        service.checkMute(at: now.addingTimeInterval(1))
        mute.labels = nil
        for s in 2...11 { service.checkMute(at: now.addingTimeInterval(Double(s))) }
        XCTAssertEqual(changes(), [true])
        service.checkMute(at: now.addingTimeInterval(12))
        XCTAssertEqual(changes(), [true, false])
        XCTAssertEqual(service.lastMutedSeen, now.addingTimeInterval(1))
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

    func testBeforeACallTheTabsAreReadOnEveryTick() {
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
        XCTAssertEqual(service.snapshot(at: now).candidates, [MeetingCandidate(platform: .teams, bundleID: "com.microsoft.teams2", micActive: true, meetingPresent: nil)])
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
        XCTAssertEqual(service.snapshot(at: now).candidates, [MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: false, meetingPresent: true)])
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

    /// A muted Zoom call releases the mic; the meeting window alone keeps the call, also past 3 minutes.
    func testAMutedZoomCallGoesOnPastThreeMinutesAndStartsWithoutTheMic() {
        let zoom = "us.zoom.xos"
        windows.running = [zoom]
        windows.titles[zoom] = ["Zoom Workplace", "Zoom Meeting"]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events, [.started(platform: .zoom, bundleID: zoom, at: now)], "joined muted: the window is enough")
        for i in 1...150 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(events.count, 1)
        windows.titles[zoom] = ["Zoom Workplace"]
        service.tick(at: now.addingTimeInterval(302))
        service.tick(at: now.addingTimeInterval(304))
        XCTAssertEqual(events.count, 2)
    }

    /// Zoom running with no meeting, and no mic: nothing starts and nothing warns.
    func testZoomRunningWithoutAMeetingIsQuiet() {
        let zoom = "us.zoom.xos"
        windows.running = [zoom]
        windows.titles[zoom] = ["Zoom Workplace"]
        var events: [DetectorEvent] = []
        var warnings: [UnconfirmedCall] = []
        service.onEvent = { events.append($0) }
        service.onUnconfirmed = { warnings.append($0) }
        for i in 0...10 { service.tick(at: now.addingTimeInterval(Double(i) * 2)) }
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(warnings.isEmpty)
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

    /// Every Teams page is a Teams tab, so a finished web call stayed "present". A tab titled as a call, once seen,
    /// ends the call when it goes.
    func testATeamsWebCallEndsWhenItsCallTabTitleGoes() {
        let chrome = "com.google.Chrome"
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs[chrome] = [BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Meeting with Dana Lee | Microsoft Teams", isActive: true)]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        mic.list = [proc(2, "com.google.Chrome.helper", input: false)]
        tabs.tabs[chrome] = [BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Chat | Microsoft Teams", isActive: true)]
        service.tick(at: now.addingTimeInterval(10))
        service.tick(at: now.addingTimeInterval(12))
        XCTAssertEqual(events.count, 2)
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
