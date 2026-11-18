import XCTest
@testable import MossadCore

final class CallTitleWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func window(_ meeting: String) -> String { "Meet - \(meeting) - Google Chrome" }

    func testTheSameTitleIsNothing() {
        var w = CallTitleWatch()
        for i in 0..<4 { XCTAssertNil(w.observe([window("Weekly sync")], at: at(Double(i) * 2))) }
        XCTAssertEqual(w.title, "Weekly sync")
    }

    func testAnotherMeetTitleOnTwoReadingsWithinTenSecondsIsAChange() {
        var w = CallTitleWatch()
        XCTAssertNil(w.observe([window("Weekly sync")], at: at(0)))
        XCTAssertNil(w.observe([window("Budget review")], at: at(2)))
        XCTAssertEqual(w.pendingSince, at(2))
        XCTAssertEqual(w.observe([window("Budget review")], at: at(4)), "Budget review")
        XCTAssertNil(w.pendingSince)
        XCTAssertEqual(w.title, "Budget review")
        XCTAssertNil(w.observe([window("Budget review")], at: at(6)))
    }

    func testOneReadingIsNotAChange() {
        var w = CallTitleWatch()
        _ = w.observe([window("Weekly sync")], at: at(0))
        XCTAssertNil(w.observe([window("Budget review")], at: at(2)))
        XCTAssertNil(w.observe([window("Weekly sync")], at: at(4)))
        XCTAssertNil(w.observe([window("Budget review")], at: at(6)), "the count starts again after the call's own title came back")
    }

    func testTwoReadingsMinutesApartAreNotAChange() {
        var w = CallTitleWatch()
        _ = w.observe([window("Weekly sync")], at: at(0))
        XCTAssertNil(w.observe([window("Budget review")], at: at(2)))
        XCTAssertNil(w.observe(nil, at: at(60)))
        XCTAssertNil(w.observe([window("Budget review")], at: at(180)))
        XCTAssertEqual(w.title, "Weekly sync")
    }

    /// The owner looks at another tab: no Meet title is no information, and the watch keeps the call's title.
    func testATitleThatIsNotMeetChangesNothingAndKeepsTheLastTitle() {
        var w = CallTitleWatch()
        _ = w.observe([window("Weekly sync")], at: at(0))
        XCTAssertNil(w.observe(["Quarterly plan - Google Docs - Google Chrome"], at: at(2)))
        XCTAssertNil(w.observe(["Inbox - Mail - Google Chrome", "Meet - Google Chrome"], at: at(4)))
        XCTAssertNil(w.observe([], at: at(6)))
        XCTAssertNil(w.observe(nil, at: at(8)))
        XCTAssertEqual(w.title, "Weekly sync")
        XCTAssertNil(w.observe([window("Weekly sync")], at: at(10)))
    }

    /// A reading with no Meet title between two readings of the new title, inside 10 s, still makes the change.
    func testNoInformationBetweenTwoReadingsInsideTenSecondsStillChanges() {
        var w = CallTitleWatch()
        _ = w.observe([window("Weekly sync")], at: at(0))
        XCTAssertNil(w.observe([window("Budget review")], at: at(2)))
        XCTAssertNil(w.observe(["Quarterly plan - Google Docs - Google Chrome"], at: at(4)))
        XCTAssertEqual(w.observe([window("Budget review")], at: at(6)), "Budget review")
    }

    /// The next meeting's waiting page in a second window, while the call's window still shows the call.
    func testTheCallsOwnTitleInAnyWindowIsNothing() {
        var w = CallTitleWatch()
        _ = w.observe([window("Weekly sync")], at: at(0))
        for i in 1...4 {
            XCTAssertNil(w.observe([window("Weekly sync"), window("Budget review")], at: at(Double(i) * 2)))
        }
    }

    func testTwoOtherMeetTitlesAreNothing() {
        var w = CallTitleWatch()
        _ = w.observe([window("Weekly sync")], at: at(0))
        XCTAssertNil(w.observe([window("Budget review"), window("Hiring loop")], at: at(2)))
        XCTAssertNil(w.observe([window("Budget review"), window("Hiring loop")], at: at(4)))
        XCTAssertEqual(w.title, "Weekly sync")
    }

    func testTheFirstTitleIsTakenOnlyWhenOneMeetTitleShows() {
        var w = CallTitleWatch()
        XCTAssertNil(w.observe([window("Weekly sync"), window("Budget review")], at: at(0)))
        XCTAssertNil(w.title)
        XCTAssertNil(w.observe([window("Budget review")], at: at(2)))
        XCTAssertEqual(w.title, "Budget review")
    }

    /// The part after the meeting's name (the browser, its profile, a sound sign) is not the meeting.
    func testOnlyTheMeetingPartOfTheWindowTitleCounts() {
        var w = CallTitleWatch()
        _ = w.observe(["Meet - abc-defg-hij - Google Chrome - Work"], at: at(0))
        XCTAssertNil(w.observe(["Meet - abc-defg-hij - Audio playing - Google Chrome - Work"], at: at(2)))
        XCTAssertNil(w.observe(["Meet – abc-defg-hij"], at: at(4)))
        XCTAssertEqual(w.title, "abc-defg-hij")
        XCTAssertNil(CallTitleWatch.meeting(inWindowTitle: "Meet - Google Chrome"), "the landing page names no meeting")
        XCTAssertNil(CallTitleWatch.meeting(inWindowTitle: "Meet"))
        XCTAssertNil(CallTitleWatch.meeting(inWindowTitle: "Docs - Meet - notes"))
    }

    /// The review's I6: a browser's name is taken off only as the end of the title, never from a meeting's name.
    func testMeetingNamesThatBeginLikeABrowserAreMeetingNames() {
        XCTAssertEqual(CallTitleWatch.meeting(inWindowTitle: "Meet - Operations review - Google Chrome"), "Operations review")
        XCTAssertEqual(CallTitleWatch.meeting(inWindowTitle: "Meet - Architecture sync – Arc"), "Architecture sync")
        XCTAssertEqual(CallTitleWatch.meeting(inWindowTitle: "Meet - Brave new plan - Brave"), "Brave new plan")
        XCTAssertEqual(CallTitleWatch.meeting(inWindowTitle: "Meet - Safari launch"), "Safari launch")
        XCTAssertEqual(CallTitleWatch.meeting(inWindowTitle: "Meet - Weekly sync - Google Chrome - Work"), "Weekly sync")
        XCTAssertNil(CallTitleWatch.meeting(inWindowTitle: "Meet - Opera"))
        XCTAssertNil(CallTitleWatch.meeting(inWindowTitle: "Meet - Google Chrome - Work"))
        var w = CallTitleWatch()
        _ = w.observe(["Meet - Operations review - Google Chrome"], at: at(0))
        XCTAssertEqual(w.title, "Operations review")
        _ = w.observe(["Meet - Budget review - Google Chrome"], at: at(2))
        XCTAssertEqual(w.observe(["Meet - Budget review - Google Chrome"], at: at(4)), "Budget review")
    }

    /// The key of a meeting's name: the first 8 bytes of its SHA-256, in hex. Never the text.
    func testTheKeyOfAMeetingName() {
        XCTAssertEqual(CallTitleWatch.key("Weekly sync"), "08786467415118f4")
        XCTAssertEqual(CallTitleWatch.key("Budget review"), "2be7ef95b4132e1d")
        XCTAssertEqual(CallTitleWatch.key("abc-defg-hij"), "fbc346f7fdf4b387")
    }

    /// A Meet title that is the meeting's code gives that code in the form of a link's id; a name gives nothing.
    func testTheMeetCodeOfATitle() {
        let rows: [(String, String?)] = [
            ("Meet - abc-defg-hij - Google Chrome", "abc-defg-hij"),
            ("Meet – abc-defg-hij – Google Chrome", "abc-defg-hij"),
            ("Meet - abc-defg-hij - Google Chrome - Work", "abc-defg-hij"),
            ("Meet - abc-defg-hij", "abc-defg-hij"),
            ("Meet - Weekly sync - Google Chrome", nil),
            ("Meet - abcd-efg-hij - Google Chrome", nil),
            ("Meet - abc-defg-hijk - Google Chrome", nil),
            ("Meet - ABC-DEFG-HIJ - Google Chrome", nil),
            ("Meet - abc-defg-hij review - Google Chrome", nil),
            ("Meet - Google Chrome", nil),
            ("Inbox - Mail - Google Chrome", nil),
        ]
        for (title, code) in rows {
            XCTAssertEqual(CallTitleWatch.meetCode(inTitle: title), code, title)
        }
        XCTAssertEqual(CallTitleWatch.meetCode(inTitle: "Meet - abc-defg-hij - Google Chrome"),
                       MeetingMatcher.meetingID(forTabURL: "https://meet.google.com/abc-defg-hij"))
    }

    /// The code is the call's link only on two readings within 10 s of exactly one Meet title, and only once.
    func testTheCodeWatchNeedsTwoReadingsWithinTenSeconds() {
        let code = window("abc-defg-hij")
        var w = TitleCodeWatch()
        XCTAssertNil(w.observe([code], at: at(0)))
        XCTAssertEqual(w.observe([code], at: at(4)), "abc-defg-hij")
        XCTAssertNil(w.observe([code], at: at(8)), "once")
        XCTAssertEqual(w.code, "abc-defg-hij")

        var far = TitleCodeWatch()
        XCTAssertNil(far.observe([code], at: at(0)))
        XCTAssertNil(far.observe([code], at: at(12)), "12 s apart: the count starts again")
        XCTAssertEqual(far.observe([code], at: at(16)), "abc-defg-hij")

        var two = TitleCodeWatch()
        XCTAssertNil(two.observe([code, window("klm-nopq-rst")], at: at(0)))
        XCTAssertNil(two.observe([code, window("klm-nopq-rst")], at: at(4)), "two meetings: not known which")

        var name = TitleCodeWatch()
        XCTAssertNil(name.observe([window("Weekly sync")], at: at(0)))
        XCTAssertNil(name.observe([window("Weekly sync")], at: at(4)), "a name is no code")

        var unknown = TitleCodeWatch()
        XCTAssertNil(unknown.observe([code], at: at(0)))
        XCTAssertNil(unknown.observe(nil, at: at(2)), "an unknown reading is no information")
        XCTAssertNil(unknown.observe(["Inbox - Mail - Google Chrome"], at: at(3)))
        XCTAssertEqual(unknown.observe([code], at: at(6)), "abc-defg-hij")

        var other = TitleCodeWatch()
        XCTAssertNil(other.observe([code], at: at(0)))
        XCTAssertNil(other.observe([window("Weekly sync")], at: at(2)))
        XCTAssertNil(other.observe([code], at: at(4)), "another title between the two readings starts the count again")
    }
}
