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
        let part = try XCTUnwrap(MeetingWindow.keptPart(of: window, bundleID: chrome, webAreas: [CGRect(x: 0, y: 120, width: 1200, height: 680)]))
        XCTAssertEqual(part.minY, 0.15, accuracy: 0.001)
        XCTAssertEqual(part.maxY, 1, accuracy: 0.001)
        XCTAssertEqual(part.width, 1, accuracy: 0.001)
        // A side panel, or tabs at the side, next to the page are cut too.
        let narrow = try XCTUnwrap(MeetingWindow.keptPart(of: window, bundleID: chrome, webAreas: [CGRect(x: 300, y: 120, width: 900, height: 680)]))
        XCTAssertEqual(narrow.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(narrow.maxX, 1, accuracy: 0.001)
        // A small second web area (a panel of the browser's own) does not stop the capture; the page is the large one.
        let withPanel = try XCTUnwrap(MeetingWindow.keptPart(of: window, bundleID: chrome,
                                                             webAreas: [CGRect(x: 1000, y: 120, width: 200, height: 300), CGRect(x: 0, y: 120, width: 1000, height: 680)]))
        XCTAssertEqual(withPanel.maxX, 1000.0 / 1200, accuracy: 0.001)
    }

    func testWithoutThePagesFrameNothingIsCapturedInAnyBrowser() {
        // No top band is guessed: where a browser has its tabs (top or side) is not known without the frame.
        for browser in [chrome, "com.microsoft.edgemac", "com.brave.Browser", "com.apple.Safari", "company.thebrowser.Browser"] {
            let window = w(1, browser, "Meet - abc-defg-hij", 1200, 1000)
            XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: browser, webAreas: nil), browser)
            XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: browser, webAreas: []), browser)
            // A frame that cannot be the page (too small, or outside the window) is no frame.
            XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: browser, webAreas: [CGRect(x: 0, y: 0, width: 80, height: 40)]), browser)
            XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: browser, webAreas: [CGRect(x: 0, y: 500, width: 2000, height: 900)]), browser)
            XCTAssertNotNil(MeetingWindow.keptPart(of: window, bundleID: browser, webAreas: [CGRect(x: 240, y: 10, width: 950, height: 980)]), browser)
        }
    }

    func testTwoPagesSideBySideAreNotCaptured() {
        let window = w(1, chrome, "Meet - abc-defg-hij - Google Chrome", 1600, 1000)
        // A split view: the meeting and the owner's mail. Which one the large area is, nobody can say.
        let split = [CGRect(x: 0, y: 90, width: 800, height: 910), CGRect(x: 800, y: 90, width: 800, height: 910)]
        XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: chrome, webAreas: split))
        XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: chrome, webAreas: split.reversed()))
        // Also when the second page is the smaller one, from about a fifth of the window.
        let uneven = [CGRect(x: 0, y: 90, width: 1200, height: 910), CGRect(x: 1200, y: 90, width: 400, height: 910)]
        XCTAssertNil(MeetingWindow.keptPart(of: window, bundleID: chrome, webAreas: uneven))
    }

    func testThePageThatMovedOrCannotBeReadEndsTheStream() {
        let page = CGRect(x: 0, y: 90, width: 1200, height: 710)
        XCTAssertFalse(MeetingWindow.pageMoved(from: page, to: page))
        XCTAssertFalse(MeetingWindow.pageMoved(from: page, to: page.offsetBy(dx: 1, dy: -2)))
        // The bookmarks bar came: the page begins 30 pt lower.
        XCTAssertTrue(MeetingWindow.pageMoved(from: page, to: CGRect(x: 0, y: 120, width: 1200, height: 680)))
        // A side panel came: the page is narrower.
        XCTAssertTrue(MeetingWindow.pageMoved(from: page, to: CGRect(x: 0, y: 90, width: 900, height: 710)))
        // Full screen with the toolbar over the page.
        XCTAssertTrue(MeetingWindow.pageMoved(from: page, to: CGRect(x: 0, y: 0, width: 1200, height: 800)))
        XCTAssertTrue(MeetingWindow.pageMoved(from: page, to: nil))
    }

    func testAChangeOfEitherEdgeOfTheWindowEndsTheStream() {
        let size = CGSize(width: 1600, height: 900)
        XCTAssertFalse(MeetingWindow.sizeChanged(from: size, to: CGSize(width: 1601, height: 899)))
        // Only the short edge: the long one is the same.
        XCTAssertTrue(MeetingWindow.sizeChanged(from: size, to: CGSize(width: 1600, height: 700)))
        XCTAssertTrue(MeetingWindow.sizeChanged(from: size, to: CGSize(width: 1500, height: 900)))
    }

    func testAppWindowsAndWindowsWithoutTabsAreKeptWhole() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(1, zoom, "Zoom Meeting"), bundleID: zoom, webAreas: nil), whole)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(1, teams, "Weekly sync | Microsoft Teams"), bundleID: teams, webAreas: nil), whole)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(9, chrome, "Meet - abc-defg-hij", 480, 270, layer: 3), bundleID: chrome, webAreas: nil), whole)
        XCTAssertEqual(MeetingWindow.keptPart(of: w(1, "com.google.Chrome.app.abcdef", "Meet - abc-defg-hij"), bundleID: chrome, webAreas: nil), whole)
    }

    func testTheKeptPartInWholePixelsStaysInsideTheFrame() {
        let p = PixelCrop.pixels(CGRect(x: 0, y: 0.15, width: 0.75, height: 0.85), width: 1600, height: 1000)
        XCTAssertEqual([p.x, p.y, p.width, p.height], [0, 150, 1200, 850])
        let all = PixelCrop.pixels(CGRect(x: 0, y: 0, width: 1, height: 1), width: 1600, height: 1000)
        XCTAssertEqual([all.x, all.y, all.width, all.height], [0, 0, 1600, 1000])
        let odd = PixelCrop.pixels(CGRect(x: 0.3333, y: 0.3333, width: 0.9, height: 0.9), width: 10, height: 10)
        XCTAssertEqual([odd.x, odd.y, odd.width, odd.height], [4, 4, 6, 6])
    }

    func testTheKeptPartIsCountedInsideTheWindowsPictureInTheFrame() {
        // The window's picture is 1600 x 800 in the middle of a 1600 x 1000 frame (the window got lower).
        let content = CGRect(x: 0, y: 100, width: 1600, height: 800)
        let p = PixelCrop.pixels(CGRect(x: 0, y: 0.15, width: 1, height: 0.85), in: content, width: 1600, height: 1000)
        XCTAssertEqual([p.x, p.y, p.width, p.height], [0, 220, 1600, 680])
        // A content rectangle that makes no sense means the whole frame.
        let none = PixelCrop.pixels(CGRect(x: 0, y: 0.5, width: 1, height: 0.5), in: .zero, width: 100, height: 100)
        XCTAssertEqual([none.x, none.y, none.width, none.height], [0, 50, 100, 50])
        let outside = PixelCrop.pixels(CGRect(x: 0, y: 0, width: 1, height: 1), in: CGRect(x: -50, y: 0, width: 400, height: 400), width: 100, height: 100)
        XCTAssertEqual([outside.x, outside.y, outside.width, outside.height], [0, 0, 100, 100])
    }

    // MARK: The same window by two names

    func testTheWindowServerTitleMatchesTheAccessibilityTitleOfTheSameWindow() {
        // Chrome adds its name, the profile, and the recording state for Accessibility.
        XCTAssertTrue(WindowTitle.same("Meet - fkq-xdfx-vbe", "Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)"))
        XCTAssertTrue(WindowTitle.same("Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)", "Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)"))
        XCTAssertTrue(WindowTitle.same("Meet – Weekly sync", "Meet – Weekly sync - Camera and microphone recording - Google Chrome"))
        XCTAssertTrue(WindowTitle.same(" Meet - abc-defg-hij ", "Meet - abc-defg-hij - Brave"))
        // Edge writes its name with a hidden character in it.
        XCTAssertTrue(WindowTitle.same("Meeting with Alex Rivera | Microsoft Teams", "Meeting with Alex Rivera | Microsoft Teams - Microsoft\u{200B} Edge"))
        XCTAssertTrue(WindowTitle.same("Meeting with Alex Rivera | Microsoft Teams", "Meeting with Alex Rivera | Microsoft Teams"))
        XCTAssertEqual(WindowTitle.core("Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)"), "Meet - fkq-xdfx-vbe")
        XCTAssertEqual(WindowTitle.core("Inbox - Gmail - Google Chrome"), "Inbox - Gmail")
    }

    func testTwoDifferentWindowsOfOneBrowserDoNotMatch() {
        XCTAssertFalse(WindowTitle.same("Meet - fkq-xdfx-vbe", "Inbox - Gmail - Google Chrome"))
        XCTAssertFalse(WindowTitle.same("Meet - fkq-xdfx-vbe", "Google Meet - Google Chrome"))
        XCTAssertFalse(WindowTitle.same("Meet - fkq-xdfx-vbe", "Meet - fkq-xdfx-vbz - Google Chrome"))
        // A start that is not a whole part of the title is no match, and a short word matches nothing longer.
        XCTAssertFalse(WindowTitle.same("Meet - fkq-xdfx", "Meet - fkq-xdfx-vbe - Google Chrome"))
        XCTAssertFalse(WindowTitle.same("Meet", "Meet - fkq-xdfx-vbe - Google Chrome"))
        XCTAssertFalse(WindowTitle.same("", "Google Chrome"))
        XCTAssertFalse(WindowTitle.same("", ""))
    }

    func testPickingTheAccessibilityWindowOfAWindowServerWindow() {
        let meet = "Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)", mail = "Inbox - Gmail - Google Chrome - Sam (Work)"
        let none: (Int) -> CGRect? = { _ in nil }
        // One candidate is picked by its title alone.
        XCTAssertEqual(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: nil, among: [mail, meet], frameOf: none), 1)
        XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: nil, among: [mail], frameOf: none))
        // The same meeting open in two windows: only the frame can tell them apart. With no sure answer, none.
        let a = CGRect(x: 0, y: 30, width: 1200, height: 800), b = CGRect(x: 300, y: 60, width: 1200, height: 800)
        XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: nil, among: [meet, meet], frameOf: none))
        XCTAssertEqual(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: b.offsetBy(dx: 1, dy: 0), among: [meet, meet], frameOf: { [a, b][$0] }), 1)
        XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: a, among: [meet, meet], frameOf: { _ in a }))
        XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: a, among: [meet, meet], frameOf: none))
    }

    func testAnEqualTitleDoesNotWinOverAnotherCandidate() {
        // Chrome's two forms of a Meet window's title for Accessibility. The window in the call has the recording
        // state in it; a second window with the same link has not, so its title is equal to the window server's.
        let inCall = "Meet - fkq-xdfx-vbe - Camera and microphone recording - Google Chrome"
        let other = "Meet - fkq-xdfx-vbe - Google Chrome - Sam (Work)"
        let callFrame = CGRect(x: 0, y: 30, width: 1400, height: 900), otherFrame = CGRect(x: 200, y: 80, width: 1000, height: 700)
        let frames = [inCall: callFrame, other: otherFrame]
        for titles in [[inCall, other], [other, inCall]] {
            let frameOf: (Int) -> CGRect? = { frames[titles[$0]] }
            // The frame decides, also against the equal title.
            XCTAssertEqual(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: callFrame, among: titles, frameOf: frameOf).map { titles[$0] }, inCall)
            XCTAssertEqual(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: otherFrame, among: titles, frameOf: frameOf).map { titles[$0] }, other)
            // With no frame, with a frame that fits neither, or with frames that cannot be read: nothing.
            XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: nil, among: titles, frameOf: frameOf))
            XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: CGRect(x: 9, y: 9, width: 500, height: 500), among: titles, frameOf: frameOf))
            XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: callFrame, among: titles, frameOf: { _ in nil }))
            // Two windows at the same place cannot be told apart.
            XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: callFrame, among: titles, frameOf: { _ in callFrame }))
        }
        // The same with the second meeting's own title strings.
        let weekly = "Meet – Weekly sync - Camera and microphone recording - Google Chrome", plain = "Meet – Weekly sync - Google Chrome"
        XCTAssertNil(WindowTitle.pick(title: "Meet – Weekly sync", frame: nil, among: [weekly, plain], frameOf: { _ in nil }))
        XCTAssertEqual(WindowTitle.pick(title: "Meet – Weekly sync", frame: callFrame, among: [plain, weekly], frameOf: { [otherFrame, callFrame][$0] }), 1)
        // A window whose title only begins the same way is a candidate too: no pick by title then.
        let notes = "Meet - fkq-xdfx-vbe - Notes - Google Chrome - Sam (Work)"
        XCTAssertNil(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe", frame: nil, among: [notes, other], frameOf: { _ in nil }))
        // The longer title of the two has one candidate only: the shorter Accessibility title is not it.
        XCTAssertEqual(WindowTitle.pick(title: "Meet - fkq-xdfx-vbe - Notes", frame: nil, among: [notes, other], frameOf: { _ in nil }), 0)
        XCTAssertFalse(WindowTitle.same("Meet - fkq-xdfx-vbe - Notes", other))
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
