import XCTest
@testable import MossadCore

final class MeetingWindowTests: XCTestCase {
    func w(_ id: UInt32, _ bundle: String, _ title: String, _ width: Double = 1200, _ height: Double = 800, on: Bool = true, layer: Int = 0) -> WindowCandidate {
        WindowCandidate(id: id, bundleID: bundle, title: title, width: width, height: height, onScreen: on, layer: layer)
    }

    let zoom = "us.zoom.xos", teams = "com.microsoft.teams2", chrome = "com.google.Chrome"

    func testZoomTakesTheMeetingWindowAndNeverTheHomeOrToolWindows() {
        let windows = [
            w(1, zoom, "Zoom Workplace"), w(2, zoom, "Zoom Meeting", 1000, 700), w(3, zoom, "zoom share toolbar window", 600, 130),
            w(4, zoom, "Meeting Chat"), w(5, "com.apple.mail", "Zoom Meeting invite"),
        ]
        XCTAssertEqual(MeetingWindow.choose(windows, platform: .zoom, bundleID: zoom)?.id, 2)
        XCTAssertNil(MeetingWindow.choose([windows[0], windows[2], windows[3], windows[4]], platform: .zoom, bundleID: zoom))
    }

    func testZoomWithTwoMeetingWindowsTakesTheOneOnScreenThenTheLarger() {
        let two = [w(1, zoom, "Zoom Meeting", 800, 600), w(2, zoom, "Zoom Meeting", 1920, 1080)]
        XCTAssertEqual(MeetingWindow.choose(two, platform: .zoom, bundleID: zoom)?.id, 2)
        let hidden = [w(1, zoom, "Zoom Meeting", 800, 600), w(2, zoom, "Zoom Meeting", 1920, 1080, on: false)]
        XCTAssertEqual(MeetingWindow.choose(hidden, platform: .zoom, bundleID: zoom)?.id, 1)
        XCTAssertEqual(MeetingWindow.choose([w(7, zoom, "Zoom Webinar")], platform: .zoom, bundleID: zoom)?.id, 7)
    }

    func testTeamsTakesTheMeetingWindowNotTheMainWindow() {
        let windows = [w(1, teams, "Chat | Dana Lee | Microsoft Teams"), w(2, teams, "Weekly sync | Microsoft Teams"), w(3, teams, "Calendar | Microsoft Teams")]
        XCTAssertEqual(MeetingWindow.choose(windows, platform: .teams, bundleID: teams)?.id, 2)
        XCTAssertNil(MeetingWindow.choose([windows[0], windows[2]], platform: .teams, bundleID: teams))
        XCTAssertNil(MeetingWindow.choose([w(4, teams, "Meeting join | Weekly sync | Microsoft Teams")], platform: .teams, bundleID: teams))
    }

    func testTeamsTakesTheCompactViewOnlyWhenTheMeetingWindowIsHidden() {
        let compact = w(5, teams, "Meeting compact view | Weekly sync | Microsoft Teams", 320, 200, layer: 3)
        let shown = [w(2, teams, "Weekly sync | Microsoft Teams"), compact]
        XCTAssertEqual(MeetingWindow.choose(shown, platform: .teams, bundleID: teams)?.id, 2)
        let hidden = [w(2, teams, "Weekly sync | Microsoft Teams", on: false), compact]
        XCTAssertEqual(MeetingWindow.choose(hidden, platform: .teams, bundleID: teams)?.id, 5)
        XCTAssertEqual(MeetingWindow.choose([compact], platform: .teams, bundleID: teams)?.id, 5)
    }

    func testTeamsTakesAPoppedOutShareOfTheMeeting() {
        let windows = [
            w(1, teams, "Chat | Dana Lee | Microsoft Teams"), w(2, teams, "Weekly sync | Microsoft Teams"),
            w(6, teams, "Sam Carter | Weekly sync | Microsoft Teams", 1600, 900),
        ]
        XCTAssertEqual(MeetingWindow.choose(windows, platform: .teams, bundleID: teams)?.id, 6)
        // With no meeting window of that name, a three-part title is the main window.
        XCTAssertNil(MeetingWindow.choose([windows[0], w(6, teams, "Sam Carter | Other | Microsoft Teams")], platform: .teams, bundleID: teams))
    }

    func testABrowserWindowCountsOnlyWhileTheMeetingIsTheTabInFront() {
        let meeting = w(1, chrome, "Meet - abc-defg-hij - Google Chrome - Robin (Work)")
        let mail = w(2, chrome, "Inbox - Mail - Google Chrome", 1800, 1100)
        XCTAssertEqual(MeetingWindow.choose([mail, meeting], platform: .meet, bundleID: chrome)?.id, 1)
        XCTAssertNil(MeetingWindow.choose([mail], platform: .meet, bundleID: chrome))
        XCTAssertNil(MeetingWindow.choose([w(3, chrome, "Google Meet - Google Chrome")], platform: .meet, bundleID: chrome))
        // The call runs in Chrome: a Meet tab in another browser is not this call.
        XCTAssertNil(MeetingWindow.choose([w(4, "com.microsoft.edgemac", "Meet - abc-defg-hij - Microsoft Edge")], platform: .meet, bundleID: chrome))
        // A helper's bundle ID names its browser.
        XCTAssertEqual(MeetingWindow.choose([meeting], platform: .meet, bundleID: "com.google.Chrome.helper")?.id, 1)
        XCTAssertTrue(MeetingWindow.stillMeeting(meeting, platform: .meet, bundleID: chrome))
        var switched = meeting
        switched.title = "Inbox - Mail - Google Chrome"
        XCTAssertFalse(MeetingWindow.stillMeeting(switched, platform: .meet, bundleID: chrome))
    }

    func testTwoMeetWindowsPreferTheCallsOwnCode() {
        let windows = [w(1, chrome, "Meet - zzz-zzzz-zzz - Google Chrome", 1800, 1100), w(2, chrome, "Meet - abc-defg-hij - Google Chrome")]
        XCTAssertEqual(MeetingWindow.choose(windows, platform: .meet, bundleID: chrome, meetingID: "abc-defg-hij")?.id, 2)
    }

    func testMeetPictureInPictureWhenTheTabIsNotInFront() {
        let pip = w(9, chrome, "Meet - abc-defg-hij", 480, 270, layer: 3)
        let mail = w(2, chrome, "Inbox - Mail - Google Chrome")
        XCTAssertEqual(MeetingWindow.choose([mail, pip], platform: .meet, bundleID: chrome)?.id, 9)
        let meeting = w(1, chrome, "Meet - abc-defg-hij - Google Chrome")
        XCTAssertEqual(MeetingWindow.choose([meeting, pip], platform: .meet, bundleID: chrome)?.id, 1)
        // A floating window of some video is not the meeting.
        XCTAssertNil(MeetingWindow.choose([mail, w(8, chrome, "Picture in picture", 480, 270, layer: 3)], platform: .meet, bundleID: chrome))
        // Safari opens no picture-in-picture of Meet by itself.
        XCTAssertNil(MeetingWindow.choose([w(9, "com.apple.Safari", "Meet - abc-defg-hij", 480, 270, layer: 3)], platform: .meet, bundleID: "com.apple.Safari"))
    }

    func testMeetAsAnInstalledAppHasItsOwnWindow() {
        let app = w(1, "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "Meet - abc-defg-hij")
        XCTAssertEqual(MeetingWindow.choose([app], platform: .meet, bundleID: chrome)?.id, 1)
    }

    func testTeamsAndZoomInABrowser() {
        XCTAssertEqual(MeetingWindow.choose([w(1, chrome, "Meeting with Dana Lee | Microsoft Teams - Google Chrome")], platform: .teams, bundleID: chrome)?.id, 1)
        XCTAssertNil(MeetingWindow.choose([w(1, chrome, "Chat | Dana Lee | Microsoft Teams - Google Chrome")], platform: .teams, bundleID: chrome))
        XCTAssertEqual(MeetingWindow.choose([w(1, chrome, "Zoom Meeting - Google Chrome")], platform: .zoom, bundleID: chrome)?.id, 1)
        XCTAssertNil(MeetingWindow.choose([w(1, chrome, "Pricing - Zoom - Google Chrome")], platform: .zoom, bundleID: chrome))
    }

    func testNothingForARoomAnUnreadableBrowserOrATinyWindow() {
        XCTAssertNil(MeetingWindow.choose([w(1, chrome, "Meet - abc-defg-hij")], platform: .inPerson, bundleID: ""))
        XCTAssertNil(MeetingWindow.choose([w(1, "org.mozilla.firefox", "Meet - abc-defg-hij")], platform: .meet, bundleID: "org.mozilla.firefox"))
        XCTAssertNil(MeetingWindow.choose([w(1, zoom, "Zoom Meeting", 300, 40)], platform: .zoom, bundleID: zoom))
    }
}
