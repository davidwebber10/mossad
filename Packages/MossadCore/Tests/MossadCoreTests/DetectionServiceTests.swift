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
    func tabs(browserBundleID: String) -> [BrowserTab]? {
        queried.append(browserBundleID)
        return tabs[browserBundleID] ?? []
    }
}

final class FakeWindows: WindowTitleProbing {
    var titles: [String: [String]] = [:]
    func windowTitles(bundleID: String) -> [String]? { titles[bundleID] }
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

    func testSnapshotGroupsBrowserHelpersUnderBaseBrowser() {
        mic.list = [proc(1, "com.google.Chrome", input: false), proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij")]
        let s = service.snapshot(at: now)
        XCTAssertEqual(s.candidates, [MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: true, meetingPresent: true)])
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
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij")]
        var events: [DetectorEvent] = []
        service.onEvent = { events.append($0) }
        service.tick(at: now)
        XCTAssertEqual(events.count, 1)
        mic.list = [proc(2, "com.google.Chrome.helper", input: false)]
        XCTAssertEqual(service.snapshot(at: now).candidates, [MeetingCandidate(platform: .meet, bundleID: "com.google.Chrome", micActive: false, meetingPresent: true)])
    }

    func testMeetPostCallPageIsGone() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij")]
        service.tick(at: now)
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet")]
        XCTAssertEqual(service.snapshot(at: now).candidates.first?.meetingPresent, false)
    }

    func testAudioProcessIDsForCurrentCall() {
        mic.list = [proc(1, "com.google.Chrome", input: false), proc(2, "com.google.Chrome.helper", input: true), proc(3, "us.zoom.xos", input: false)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij")]
        XCTAssertEqual(service.audioProcessIDs, [])
        service.tick(at: now)
        XCTAssertEqual(service.audioProcessIDs, [1, 2])
    }

    func testReportsCallProcessesEachTick() {
        mic.list = [proc(2, "com.google.Chrome.helper", input: true)]
        tabs.tabs["com.google.Chrome"] = [BrowserTab(url: "https://meet.google.com/abc-defg-hij", title: "Meet - abc-defg-hij")]
        var reports: [[AudioObjectID]] = []
        service.onCallProcesses = { reports.append($0) }
        service.tick(at: now)
        mic.list = [proc(2, "com.google.Chrome.helper", input: true), proc(7, "com.google.Chrome.helper", input: false)]
        service.tick(at: now.addingTimeInterval(2))
        XCTAssertEqual(reports, [[2], [2, 7]])
    }
}
