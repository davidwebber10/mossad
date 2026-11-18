import XCTest
@testable import MossadCore

final class CallLinkWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func meet(_ code: String, inCall: Bool = true, active: Bool = false) -> BrowserTab {
        BrowserTab(url: "https://meet.google.com/\(code)?authuser=0", title: inCall ? "Meet - \(code)" : "Meet", isActive: active)
    }

    func testTheSameLinkStillInAMeetingIsNothing() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        for i in 0..<3 { XCTAssertEqual(w.observe([meet("abc-defg-hij")], at: at(Double(i) * 2)), .none) }
        XCTAssertEqual(w.link, "abc-defg-hij")
    }

    func testTheLinkGoneWithNoOtherMeetingIsNothing() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        XCTAssertEqual(w.observe([], at: at(0)), .none)
        XCTAssertEqual(w.observe([meet("abc-defg-hij", inCall: false)], at: at(2)), .none)
        XCTAssertEqual(w.observe([BrowserTab(url: "https://example.com", title: "News")], at: at(4)), .none)
        XCTAssertFalse(w.isPending(at: at(4)))
    }

    /// The call's own tab is still open on its address, and its title left the meeting: a reload or a lost connection
    /// looks the same for some seconds, so the change must last 30 s, with sure readings no more than 10 s apart.
    func testTheOwnTabStillOpenAndLeftNeedsThirtySeconds() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        let list = [meet("abc-defg-hij", inCall: false), meet("klm-nopq-rst", active: true)]
        XCTAssertEqual(w.observe(list, at: at(0)), .none)
        XCTAssertTrue(w.isPending(at: at(2)))
        XCTAssertEqual(w.pendingSince(at: at(2)), at(0))
        for s in stride(from: 4.0, to: 30, by: 4) { XCTAssertEqual(w.observe(list, at: at(s)), .none) }
        XCTAssertEqual(w.observe(list, at: at(32)), .newCall("klm-nopq-rst", .meet))
        XCTAssertFalse(w.isPending(at: at(32)))
        XCTAssertEqual(w.link, "klm-nopq-rst")
    }

    /// The review's I3: a reload of the call's tab while the next meeting's waiting page is open is no change.
    func testAReloadOfTheOwnTabWithAnotherMeetingOpenIsNothing() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        let reloading = [meet("abc-defg-hij", inCall: false), meet("klm-nopq-rst")]
        let back = [meet("abc-defg-hij", active: true), meet("klm-nopq-rst")]
        for s in stride(from: 0.0, through: 8, by: 2) { XCTAssertEqual(w.observe(reloading, at: at(s)), .none) }
        XCTAssertEqual(w.observe(back, at: at(10)), .none)
        XCTAssertFalse(w.isPending(at: at(10)))
        for s in stride(from: 12.0, through: 60, by: 2) { XCTAssertEqual(w.observe(back, at: at(s)), .none) }
        XCTAssertEqual(w.link, "abc-defg-hij")
    }

    /// The long wait also forgets a change whose sure readings are more than 10 s apart.
    func testTheLongWaitNeedsReadingsNoMoreThanTenSecondsApart() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        let list = [meet("abc-defg-hij", inCall: false), meet("klm-nopq-rst")]
        XCTAssertEqual(w.observe(list, at: at(0)), .none)
        XCTAssertEqual(w.observe(list, at: at(8)), .none)
        XCTAssertEqual(w.observe(nil, at: at(14)), .none)
        XCTAssertEqual(w.observe(list, at: at(20)), .none, "12 s after the last sure reading: a new wait")
        XCTAssertEqual(w.pendingSince(at: at(20)), at(20))
        XCTAssertEqual(w.observe(list, at: at(28)), .none)
        XCTAssertEqual(w.observe(list, at: at(36)), .none)
        XCTAssertEqual(w.observe(list, at: at(44)), .none)
        XCTAssertEqual(w.observe(list, at: at(50)), .newCall("klm-nopq-rst", .meet))
    }

    func testTheTabThatMovedToAnotherLinkIsANewCall() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(0)), .none)
        XCTAssertEqual(w.pendingSince(at: at(2)), at(0), "the time of the first reading of the change")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(2)), .newCall("klm-nopq-rst", .meet))
    }

    /// A breakout room and the return: the watch's own link follows each decision, so the way back is a second change.
    func testAChangeBackAfterANewCallIsASecondChange() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        _ = w.observe([meet("klm-nopq-rst")], at: at(0))
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(2)), .newCall("klm-nopq-rst", .meet))
        XCTAssertEqual(w.observe([meet("abc-defg-hij")], at: at(60)), .none)
        XCTAssertEqual(w.observe([meet("abc-defg-hij")], at: at(62)), .newCall("abc-defg-hij", .meet))
    }

    func testAnotherPlatformInTheSameBrowserIsANewCall() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        let zoom = BrowserTab(url: "https://us02web.zoom.us/wc/81234567890/join", title: "Zoom", isActive: true)
        XCTAssertEqual(w.observe([zoom], at: at(0)), .none)
        XCTAssertEqual(w.observe([zoom], at: at(2)), .newCall("81234567890", .zoom))
    }

    func testBothLinksInAMeetingIsNothing() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        let list = [meet("abc-defg-hij"), meet("klm-nopq-rst", active: true)]
        for i in 0..<4 { XCTAssertEqual(w.observe(list, at: at(Double(i) * 2)), .none) }
        XCTAssertFalse(w.isPending(at: at(6)))
    }

    func testAnUnknownListChangesNothingAndTwoSureReadingsInsideTenSecondsStillDecide() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        XCTAssertEqual(w.observe(nil, at: at(0)), .none)
        XCTAssertFalse(w.isPending(at: at(0)))
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(2)), .none)
        XCTAssertEqual(w.observe(nil, at: at(4)), .none)
        XCTAssertEqual(w.observe(nil, at: at(8)), .none)
        XCTAssertTrue(w.isPending(at: at(8)))
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(12)), .newCall("klm-nopq-rst", .meet))
    }

    /// The fault of the rejected branch: two stray readings minutes apart, with only unknown ones between, added up.
    func testTwoStrayReadingsThreeMinutesApartMakeNoMark() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(0)), .none)
        for s in stride(from: 2.0, to: 180, by: 2) { XCTAssertEqual(w.observe(nil, at: at(s)), .none) }
        XCTAssertFalse(w.isPending(at: at(180)), "a waiting change older than 10 s is forgotten")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(180)), .none)
        XCTAssertEqual(w.link, "abc-defg-hij")
    }

    /// An unknown reading does not make a waiting change younger.
    func testAnUnknownReadingDoesNotRefreshTheWaitingChange() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        _ = w.observe([meet("klm-nopq-rst")], at: at(0))
        _ = w.observe(nil, at: at(9))
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(11)), .none)
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(13)), .newCall("klm-nopq-rst", .meet),
                       "the reading at 11 s starts a new wait, and the one at 13 s decides")
    }

    func testOneStrayReadingDoesNotMarkTheCall() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(0)), .none)
        XCTAssertEqual(w.observe([meet("abc-defg-hij"), meet("klm-nopq-rst")], at: at(2)), .none)
        XCTAssertFalse(w.isPending(at: at(2)))
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(4)), .none, "the count starts again after the call's own link came back")
    }

    func testTwoReadingsOfDifferentNewLinksDoNotAddUp() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst")], at: at(0)), .none)
        XCTAssertEqual(w.observe([meet("uvw-xyza-bcd")], at: at(2)), .none)
        XCTAssertEqual(w.observe([meet("uvw-xyza-bcd")], at: at(4)), .newCall("uvw-xyza-bcd", .meet))
    }

    func testTwoOtherMeetingsOrAMeetingWithNoLinkIsNothing() {
        var w = CallLinkWatch(link: "abc-defg-hij")
        let two = [meet("klm-nopq-rst"), meet("uvw-xyza-bcd")]
        XCTAssertEqual(w.observe(two, at: at(0)), .none)
        XCTAssertEqual(w.observe(two, at: at(2)), .none)
        let teamsShell = BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Chat | Microsoft Teams")
        XCTAssertEqual(w.observe([meet("klm-nopq-rst"), teamsShell], at: at(4)), .none)
        XCTAssertEqual(w.observe([meet("klm-nopq-rst"), teamsShell], at: at(6)), .none)
        XCTAssertFalse(w.isPending(at: at(6)))
    }

    func testACallWithNoLinkAdoptsTheOneMeetingAndNeverMarksBefore() {
        var w = CallLinkWatch(link: nil)
        XCTAssertEqual(w.observe(nil, at: at(0)), .none)
        XCTAssertEqual(w.observe([meet("abc-defg-hij"), meet("klm-nopq-rst")], at: at(2)), .none, "two meetings: no link is sure")
        XCTAssertNil(w.link)
        XCTAssertEqual(w.observe([meet("abc-defg-hij")], at: at(4)), .adopt("abc-defg-hij"))
        XCTAssertEqual(w.link, "abc-defg-hij")
        XCTAssertEqual(w.observe([meet("abc-defg-hij")], at: at(6)), .none)
    }

    func testACallWithNoLinkDoesNotAdoptATabWithNoLink() {
        var w = CallLinkWatch(link: nil)
        XCTAssertEqual(w.observe([BrowserTab(url: "https://teams.microsoft.com/v2/", title: "Meeting | Microsoft Teams")], at: at(0)), .none)
        XCTAssertNil(w.link)
    }

    /// What `MeetingMatcher.meetingID(forTabURL:)` gives decides where the rule applies.
    func testLinksOfEachPlatform() {
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://meet.google.com/abc-defg-hij?authuser=1"), "abc-defg-hij")
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://zoom.us/wc/join/81234567890"), "81234567890")
        XCTAssertNil(MeetingMatcher.meetingID(forTabURL: "https://zoom.us/wc/leave"))
        XCTAssertEqual(MeetingMatcher.meetingID(forTabURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjA2YTk@thread.v2/0"),
                       "meeting_NjA2YTk")
        XCTAssertNil(MeetingMatcher.meetingID(forTabURL: "https://teams.microsoft.com/v2/"))
    }
}
