import XCTest
@testable import MossadCore

final class MeetingMatcherTests: XCTestCase {
    func testAppKinds() {
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "us.zoom.xos"), .zoomApp)
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.microsoft.teams2"), .teamsApp)
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.google.Chrome"), .browser("com.google.Chrome"))
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.google.Chrome.helper"), .browser("com.google.Chrome"))
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "company.thebrowser.Browser"), .browser("company.thebrowser.Browser"))
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.apple.Safari"), .browser("com.apple.Safari"))
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.apple.WebKit.GPU"), .browser("com.apple.Safari"))
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.microsoft.edgemac"), .browser("com.microsoft.edgemac"))
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.brave.Browser"), .browser("com.brave.Browser"))
        XCTAssertNil(MeetingMatcher.appKind(bundleID: "com.spotify.client"))
    }

    func testMeetingIDFromTabURL() {
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://meet.google.com/abc-defg-hij?authuser=1"), "abc-defg-hij")
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://meet.google.com/meet/zpg-fuzw-ejj"), "zpg-fuzw-ejj")
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://app.zoom.us/wc/81234567890/join?pwd=x"), "81234567890")
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://example.zoom.us/wc/join/81234567890"), "81234567890")
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjQ1ZDk2%40thread.v2/0?context=x"), "meeting_NjQ1ZDk2")
        XCTAssertNil(MeetingMatcher.meetingID(forTabURL: "https://teams.microsoft.com/v2/"))
        XCTAssertNil(MeetingMatcher.meetingID(forTabURL: "https://www.youtube.com/watch?v=x"))
    }

    func testTabURLPlatforms() {
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://meet.google.com/abc-defg-hij"), .meet)
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://meet.google.com/abc-defg-hij?authuser=1"), .meet)
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://meet.google.com/meet/abc-defg-hij"), .meet)
        XCTAssertNil(MeetingMatcher.platform(forTabURL: "https://meet.google.com/meet/"))
        XCTAssertNil(MeetingMatcher.platform(forTabURL: "https://meet.google.com/"))
        XCTAssertNil(MeetingMatcher.platform(forTabURL: "https://meet.google.com/landing"))
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://teams.microsoft.com/v2/"), .teams)
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://teams.cloud.microsoft/"), .teams)
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting"), .teams)
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://app.zoom.us/wc/123456/join"), .zoom)
        XCTAssertEqual(MeetingMatcher.platform(forTabURL: "https://us02web.zoom.us/wc/123/start"), .zoom)
        XCTAssertNil(MeetingMatcher.platform(forTabURL: "https://zoom.us/pricing"))
        XCTAssertNil(MeetingMatcher.platform(forTabURL: "https://www.youtube.com/watch?v=x"))
    }

    func testBrowserMicWithoutMeetingTabIsNotACall() {
        let tabs = ["https://www.youtube.com/watch?v=x", "https://docs.google.com/document/d/1", "https://mail.google.com/"]
        XCTAssertTrue(tabs.compactMap(MeetingMatcher.platform(forTabURL:)).isEmpty)
    }

    func testZoomWindowTitles() {
        XCTAssertTrue(MeetingMatcher.zoomWindowIsMeeting("Zoom Meeting"))
        XCTAssertTrue(MeetingMatcher.zoomWindowIsMeeting("Zoom Webinar"))
        XCTAssertFalse(MeetingMatcher.zoomWindowIsMeeting("Zoom Workplace"))
        XCTAssertFalse(MeetingMatcher.zoomWindowIsMeeting("Zoom"))
    }

    func testTeamsWindowTitles() {
        XCTAssertTrue(MeetingMatcher.teamsWindowIsMeeting("Meeting with Alex Rivera | Microsoft Teams"))
        XCTAssertTrue(MeetingMatcher.teamsWindowIsMeeting("Call with Alex Rivera | Microsoft Teams"))
        XCTAssertFalse(MeetingMatcher.teamsWindowIsMeeting("Chat | Alex Rivera | Microsoft Teams"))
        XCTAssertFalse(MeetingMatcher.teamsWindowIsMeeting("Calendar | Microsoft Teams"))
    }

    func testMeetTabLeftMeeting() {
        XCTAssertFalse(MeetingMatcher.meetTabLeftMeeting(title: "Meet - abc-defg-hij"))
        XCTAssertFalse(MeetingMatcher.meetTabLeftMeeting(title: "Meet – Weekly Ops Sync"))
        XCTAssertTrue(MeetingMatcher.meetTabLeftMeeting(title: "Meet"))
        XCTAssertTrue(MeetingMatcher.meetTabLeftMeeting(title: "Google Meet"))
    }

    func testPlatformDisplayNames() {
        XCTAssertEqual(Platform.zoom.displayName, "Zoom")
        XCTAssertEqual(Platform.meet.displayName, "Google Meet")
        XCTAssertEqual(Platform.teams.displayName, "Microsoft Teams")
    }
}

final class MeetingMatcherHelperTests: XCTestCase {
    func testNativeAppHelpersMapToApp() {
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "com.microsoft.teams2.helper"), .teamsApp)
        XCTAssertEqual(MeetingMatcher.appKind(bundleID: "us.zoom.xos.Helper"), .zoomApp)
    }
}
