import XCTest
@testable import MossadCore

final class UnconfirmedCallWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    let chrome = UnconfirmedCall(bundleID: "com.google.Chrome", platform: nil, reason: .cannotSeeMeeting)

    func testWarnsOnceAfterTheMicStaysOnForTenSeconds() {
        var watch = UnconfirmedCallWatch()
        XCTAssertNil(watch.update(at: t0, suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(8), suspects: [chrome], inCall: false))
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: false), chrome)
        // The same mic session never warns twice, also after "Not a call".
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(12), suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(300), suspects: [chrome], inCall: false))
    }

    func testABriefMicUseDoesNotWarn() {
        var watch = UnconfirmedCallWatch()
        XCTAssertNil(watch.update(at: t0, suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(4), suspects: [], inCall: false))
        // A new session after a long quiet gap starts the count again.
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(100), suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(105), suspects: [chrome], inCall: false))
    }

    func testANewMicSessionLaterWarnsAgain() {
        var watch = UnconfirmedCallWatch()
        _ = watch.update(at: t0, suspects: [chrome], inCall: false)
        XCTAssertNotNil(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(200), suspects: [chrome], inCall: false))
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(210), suspects: [chrome], inCall: false), chrome)
    }

    func testNoWarningDuringACall() {
        var watch = UnconfirmedCallWatch()
        _ = watch.update(at: t0, suspects: [chrome], inCall: false)
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: true))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(12), suspects: [chrome], inCall: false))
    }

    /// "Not a call" once only lasted for the mic session; dictation a few times an hour warned each time.
    func testNotACallLastsUntilItsTime() {
        var watch = UnconfirmedCallWatch()
        watch.dismiss(chrome, until: t0.addingTimeInterval(3600))
        for s in stride(from: 0.0, through: 600, by: 2) { XCTAssertNil(watch.update(at: t0.addingTimeInterval(s), suspects: [chrome], inCall: false)) }
        // Another reason for the same app still warns.
        let background = UnconfirmedCall(bundleID: "com.google.Chrome", platform: .meet, reason: .meetingTabNotSelected)
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(1000), suspects: [background], inCall: false))
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(1010), suspects: [background], inCall: false), background)
        // After the time, the warning comes back.
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(3700), suspects: [chrome], inCall: false))
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(3710), suspects: [chrome], inCall: false), chrome)
    }

    func testResetKeepsTheDismissals() {
        var watch = UnconfirmedCallWatch()
        watch.dismiss(chrome, until: t0.addingTimeInterval(3600))
        watch.reset()
        XCTAssertNil(watch.update(at: t0, suspects: [chrome], inCall: false))
        XCTAssertNil(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome], inCall: false))
    }

    /// Two apps in the same tick: the second warns on the next tick, not never.
    func testTwoSuspectsBothWarn() {
        var watch = UnconfirmedCallWatch()
        let firefox = UnconfirmedCall(bundleID: "org.mozilla.firefox", platform: nil, reason: .cannotSeeMeeting)
        _ = watch.update(at: t0, suspects: [chrome, firefox], inCall: false)
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(10), suspects: [chrome, firefox], inCall: false), chrome)
        XCTAssertEqual(watch.update(at: t0.addingTimeInterval(12), suspects: [chrome, firefox], inCall: false), firefox)
    }

    func testNotACallAnswersSurviveARestart() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var book = UnconfirmedDismissals()
        let chrome = UnconfirmedCall(bundleID: "com.google.Chrome", platform: .teams, reason: .meetingTabNotSelected)
        book.add(chrome, until: now.addingTimeInterval(3600), now: now)
        book.add(UnconfirmedCall(bundleID: "us.zoom.xos", platform: .zoom, reason: .noMeetingWindow), until: now.addingTimeInterval(60), now: now)
        let loaded = UnconfirmedDismissals(data: book.data)
        XCTAssertEqual(loaded, book)
        let later = loaded.active(at: now.addingTimeInterval(120))
        XCTAssertEqual(later.map(\.call.bundleID), ["com.google.Chrome"])
        XCTAssertEqual(later.first?.call.reason, .meetingTabNotSelected)
        XCTAssertEqual(UnconfirmedDismissals(data: Data("junk".utf8)), UnconfirmedDismissals())
    }

    func testNotACallHoldsForTheRestOfTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let afternoon = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        let end = UnconfirmedDismissals.endOfDay(after: afternoon, calendar: calendar)
        XCTAssertEqual(end.timeIntervalSince1970, 1_800_057_600)
    }
}
