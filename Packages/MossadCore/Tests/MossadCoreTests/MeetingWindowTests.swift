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

    let weekly = "Weekly sync | Microsoft Teams"

    func testTeamsTakesTheMeetingWindowOnlyWithProof() {
        let windows = [w(1, teams, "Chat | Dana Lee | Microsoft Teams"), w(2, teams, weekly), w(3, teams, "Calendar | Microsoft Teams")]
        // The title alone proves nothing: the main window shows its pages with the same form.
        XCTAssertNil(MeetingWindow.choose(windows, platform: .teams, bundleID: teams))
        XCTAssertEqual(MeetingWindow.teamsTitlesToProve(windows.map(\.title)), [weekly])
        // Accessibility found the call's controls in it.
        XCTAssertEqual(MeetingWindow.choose(windows, platform: .teams, bundleID: teams, confirmed: [weekly])?.id, 2)
        XCTAssertNil(MeetingWindow.choose([w(4, teams, "Meeting join | Weekly sync | Microsoft Teams")], platform: .teams, bundleID: teams))
        // A title that says "Meeting with" or "Call with" is the app's own name for a call.
        XCTAssertEqual(MeetingWindow.choose([w(5, teams, "Meeting with Alex Rivera | Microsoft Teams")], platform: .teams, bundleID: teams)?.id, 5)
        XCTAssertEqual(MeetingWindow.teamsTitlesToProve(["Meeting with Alex Rivera | Microsoft Teams", "Calendar | Microsoft Teams"]), [])
    }

    func testTeamsNeverTakesAPageOfTheMainWindowHoweverLarge() {
        // An app page, a section Microsoft adds later, and a section in another language: none is in any list.
        for page in ["Power BI | Microsoft Teams", "Viva Insights | Microsoft Teams", "Kalender | Microsoft Teams", "Loop | Microsoft Teams"] {
            let windows = [w(1, teams, page, 2400, 1600), w(2, teams, weekly, 900, 600)]
            XCTAssertNil(MeetingWindow.choose([windows[0]], platform: .teams, bundleID: teams), page)
            // With the meeting proven, the larger main window still loses.
            XCTAssertEqual(MeetingWindow.choose(windows, platform: .teams, bundleID: teams, confirmed: [weekly])?.id, 2, page)
            // With nothing proven, nothing is captured.
            XCTAssertNil(MeetingWindow.choose(windows, platform: .teams, bundleID: teams), page)
        }
        // A known section is refused also when something claims it is a call.
        XCTAssertNil(MeetingWindow.choose([w(1, teams, "Calls | Microsoft Teams")], platform: .teams, bundleID: teams, confirmed: ["Calls | Microsoft Teams"]))
    }

    func testTeamsTakesTheCompactViewOnlyWhenTheMeetingWindowIsHidden() {
        let compact = w(5, teams, "Meeting compact view | Weekly sync | Microsoft Teams", 320, 200, layer: 3)
        // The compact view names the meeting, so its own window needs no other proof.
        let shown = [w(2, teams, weekly), compact]
        XCTAssertEqual(MeetingWindow.choose(shown, platform: .teams, bundleID: teams)?.id, 2)
        let hidden = [w(2, teams, weekly, on: false), compact]
        XCTAssertEqual(MeetingWindow.choose(hidden, platform: .teams, bundleID: teams)?.id, 5)
        XCTAssertEqual(MeetingWindow.choose([compact], platform: .teams, bundleID: teams)?.id, 5)
    }

    func testTeamsTakesAPoppedOutShareOnlyWhenItsTitleSaysSo() {
        let chat = w(1, teams, "Chat | Dana Lee | Microsoft Teams"), meeting = w(2, teams, weekly)
        let share = w(6, teams, "Shared content | Weekly sync | Microsoft Teams", 1600, 900)
        XCTAssertEqual(MeetingWindow.choose([chat, meeting, share], platform: .teams, bundleID: teams, confirmed: [weekly])?.id, 6)
        // Another window that names the meeting (its chat, in any language) is not the share.
        for title in ["Sam Carter | Weekly sync | Microsoft Teams", "Unterhaltung | Weekly sync | Microsoft Teams", "Chat | Weekly sync | Microsoft Teams"] {
            XCTAssertEqual(MeetingWindow.choose([meeting, w(7, teams, title, 2400, 1600)], platform: .teams, bundleID: teams, confirmed: [weekly])?.id, 2, title)
        }
        // A share of a meeting that is not proven is not taken.
        XCTAssertNil(MeetingWindow.choose([chat, share], platform: .teams, bundleID: teams))
        // The window still counts while its title fits a proven name, and no longer when it does not.
        XCTAssertTrue(MeetingWindow.stillMeeting(meeting, platform: .teams, bundleID: teams, meetingNames: ["Weekly sync"]))
        XCTAssertFalse(MeetingWindow.stillMeeting(w(2, teams, "Power BI | Microsoft Teams"), platform: .teams, bundleID: teams, meetingNames: ["Weekly sync"]))
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
        // The pages of Teams in a browser that are not a call.
        for page in ["Calls | Microsoft Teams", "Calendar | Microsoft Teams", "Activity | Microsoft Teams", "Meet | Microsoft Teams",
                     "Chat | Meeting with Dana Lee | Microsoft Teams", "Callum Reed | Microsoft Teams", "Meeting join | Microsoft Teams"] {
            XCTAssertNil(MeetingWindow.choose([w(1, chrome, page + " - Google Chrome")], platform: .teams, bundleID: chrome), page)
            XCTAssertFalse(MeetingWindow.stillMeeting(w(1, chrome, page + " - Google Chrome"), platform: .teams, bundleID: chrome), page)
        }
        XCTAssertEqual(MeetingWindow.choose([w(1, chrome, "Call with Dana Lee | Microsoft Teams - Google Chrome")], platform: .teams, bundleID: chrome)?.id, 1)
        XCTAssertEqual(MeetingWindow.choose([w(1, chrome, "Zoom Meeting - Google Chrome")], platform: .zoom, bundleID: chrome)?.id, 1)
        XCTAssertNil(MeetingWindow.choose([w(1, chrome, "Pricing - Zoom - Google Chrome")], platform: .zoom, bundleID: chrome))
    }

    func testNothingForARoomAnUnreadableBrowserOrATinyWindow() {
        XCTAssertNil(MeetingWindow.choose([w(1, chrome, "Meet - abc-defg-hij")], platform: .inPerson, bundleID: ""))
        XCTAssertNil(MeetingWindow.choose([w(1, "org.mozilla.firefox", "Meet - abc-defg-hij")], platform: .meet, bundleID: "org.mozilla.firefox"))
        XCTAssertNil(MeetingWindow.choose([w(1, zoom, "Zoom Meeting", 300, 40)], platform: .zoom, bundleID: zoom))
    }

    // MARK: The kept part of a browser window

    func testABrowserFrameKeepsOnlyThePage() throws {
        let window = w(1, chrome, "Meet - abc-defg-hij - Google Chrome", 1200, 800)
        // The page's frame from Accessibility: under 120 pt of tabs, address, and bookmarks.
        let part = try XCTUnwrap(MeetingWindow.keptPart(of: window, bundleID: chrome, webArea: CGRect(x: 0, y: 120, width: 1200, height: 680)))
        XCTAssertEqual(part.minY, 0.15, accuracy: 0.001)
        XCTAssertEqual(part.maxY, 1, accuracy: 0.001)
        XCTAssertEqual(part.width, 1, accuracy: 0.001)
        // A side panel next to the page is cut too.
        let narrow = try XCTUnwrap(MeetingWindow.keptPart(of: window, bundleID: chrome, webArea: CGRect(x: 0, y: 120, width: 900, height: 680)))
        XCTAssertEqual(narrow.maxX, 0.75, accuracy: 0.001)
    }

    func testWithoutThePagesFrameTheTopBandIsCut() throws {
        let window = w(1, chrome, "Meet - abc-defg-hij - Google Chrome", 1200, 1000)
        for area in [nil, CGRect(x: 0, y: 0, width: 80, height: 40), CGRect(x: 0, y: 500, width: 2000, height: 900)] {
            let part = try XCTUnwrap(MeetingWindow.keptPart(of: window, bundleID: chrome, webArea: area))
            XCTAssertEqual(part.minY, 0.125, accuracy: 0.001)
            XCTAssertEqual(part.height, 0.875, accuracy: 0.001)
        }
        // A window too low for the band, and a browser with its tabs at the side, are not captured without the frame.
        XCTAssertNil(MeetingWindow.keptPart(of: w(1, chrome, "Meet - abc-defg-hij", 600, 200), bundleID: chrome, webArea: nil))
        let arc = "company.thebrowser.Browser"
        XCTAssertNil(MeetingWindow.keptPart(of: w(1, arc, "Meet - abc-defg-hij", 1200, 1000), bundleID: arc, webArea: nil))
        XCTAssertNotNil(MeetingWindow.keptPart(of: w(1, arc, "Meet - abc-defg-hij", 1200, 1000), bundleID: arc, webArea: CGRect(x: 240, y: 10, width: 950, height: 980)))
    }

    func testAppWindowsAndWindowsWithoutTabsAreKeptWhole() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(1, zoom, "Zoom Meeting"), bundleID: zoom, webArea: nil), whole)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(1, teams, "Weekly sync | Microsoft Teams"), bundleID: teams, webArea: nil), whole)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(9, chrome, "Meet - abc-defg-hij", 480, 270, layer: 3), bundleID: chrome, webArea: nil), whole)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(1, "com.google.Chrome.app.abcdef", "Meet - abc-defg-hij"), bundleID: chrome, webArea: nil), whole)
    }

    func testTheKeptPartInWholePixelsStaysInsideTheFrame() {
        let p = PixelCrop.pixels(CGRect(x: 0, y: 0.15, width: 0.75, height: 0.85), width: 1600, height: 1000)
        XCTAssertEqual([p.x, p.y, p.width, p.height], [0, 150, 1200, 850])
        let all = PixelCrop.pixels(CGRect(x: 0, y: 0, width: 1, height: 1), width: 1600, height: 1000)
        XCTAssertEqual([all.x, all.y, all.width, all.height], [0, 0, 1600, 1000])
        let odd = PixelCrop.pixels(CGRect(x: 0.3333, y: 0.3333, width: 0.9, height: 0.9), width: 10, height: 10)
        XCTAssertEqual([odd.x, odd.y, odd.width, odd.height], [4, 4, 6, 6])
    }

    // MARK: Covered windows

    func testAWindowCoveredByOthersIsNotOnScreen() {
        let window = CGRect(x: 100, y: 100, width: 1000, height: 800)
        XCTAssertFalse(WindowCover.isCovered(window, by: []))
        XCTAssertTrue(WindowCover.isCovered(window, by: [CGRect(x: 0, y: 0, width: 2000, height: 1200)]))
        // Half covered still shows.
        XCTAssertEqual(WindowCover.coveredPart(of: window, by: [CGRect(x: 0, y: 0, width: 600, height: 2000)]), 0.5, accuracy: 0.001)
        // Two windows that cover it together; where they overlap counts one time.
        let two = [CGRect(x: 0, y: 0, width: 700, height: 2000), CGRect(x: 500, y: 0, width: 700, height: 2000)]
        XCTAssertEqual(WindowCover.coveredPart(of: window, by: two), 1, accuracy: 0.001)
        // A strip of 6 percent that still shows is not "covered".
        XCTAssertFalse(WindowCover.isCovered(window, by: [CGRect(x: 0, y: 0, width: 1040, height: 2000)]))
        XCTAssertTrue(WindowCover.isCovered(window, by: [CGRect(x: 0, y: 0, width: 1060, height: 2000)]))
        // A window on another display covers nothing.
        XCTAssertEqual(WindowCover.coveredPart(of: window, by: [CGRect(x: 3000, y: 0, width: 1000, height: 1000)]), 0)
    }
}
