import XCTest
@testable import MossadCore

final class CoachEmailTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        return c
    }()

    func testTheMonthlyEmailIsDueOnceAfterTheFirstMorningAndCoversLastMonth() {
        func date(_ m: Int, _ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }
        XCTAssertFalse(MonthlySchedule.isDue(lastSent: date(10, 1, 9), now: date(10, 31, 20), calendar: cal))
        XCTAssertFalse(MonthlySchedule.isDue(lastSent: date(10, 1, 9), now: date(11, 1, 7), calendar: cal))
        XCTAssertTrue(MonthlySchedule.isDue(lastSent: date(10, 1, 9), now: date(11, 1, 8), calendar: cal))
        XCTAssertTrue(MonthlySchedule.isDue(lastSent: nil, now: date(11, 3, 8), calendar: cal))
        let range = MonthlySchedule.range(before: date(11, 3, 12), calendar: cal)
        XCTAssertEqual(range.start, date(10, 1, 0))
        XCTAssertEqual(range.end, date(11, 1, 0))
    }

    private func facts() -> EmailFacts {
        var overdue = Commitment(text: "Send Ben the <org> chart", to: "Ben", callID: "c", callTitle: "1:1", madeAt: Date(), due: Date().addingTimeInterval(-86_400 * 2))
        overdue.at = 10
        return EmailFacts(calls: 12, previousCalls: 10, seconds: 9 * 3600, previousSeconds: 6 * 3600, talkShare: 0.41,
                          focusPlan: "Date every commitment.", focusResults: [.hit, .missed, .noChance, .hit],
                          overdue: [overdue], dueSoon: [], doneCount: 3)
    }

    private let digest = WeeklyDigest(subject: "A sharper week", intro: "You led <well>.", improved: ["Shorter turns."],
                                      toWork: ["Date your items."], focus: "Two hits in three chances.", bestMoment: "“Here's my recommendation.” (Budget, Oct 14)")

    func testTheEmailShowsTheNumbersTheFocusAndTheCommitments() {
        let html = CoachEmailDesign.html(kind: .weekly, period: "Oct 12 – 18", digest: digest, facts: facts())
        XCTAssertTrue(html.contains("A sharper week"))
        XCTAssertTrue(html.contains("You led &lt;well&gt;."))
        XCTAssertTrue(html.contains(">12<"), "meetings")
        XCTAssertTrue(html.contains("+20%"), "meetings against the week before")
        XCTAssertTrue(html.contains("9 h"))
        XCTAssertTrue(html.contains("41%"))
        XCTAssertTrue(html.contains("Date every commitment."))
        XCTAssertTrue(html.contains("2 of 3 chances"))
        XCTAssertTrue(html.contains("Send Ben the &lt;org&gt; chart"))
        XCTAssertTrue(html.contains("3 done"))
        XCTAssertTrue(html.contains("Here's my recommendation."))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        let text = CoachEmailDesign.text(kind: .weekly, period: "Oct 12 – 18", digest: digest, facts: facts())
        XCTAssertTrue(text.contains("Overdue:\n- Send Ben the <org> chart"))
        XCTAssertTrue(text.contains("12 meetings"))
    }

    func testAMonthlyEmailSaysMonth() {
        let html = CoachEmailDesign.html(kind: .monthly, period: "October 2026", digest: digest, facts: facts())
        XCTAssertTrue(html.contains("MONTH IN REVIEW"))
        XCTAssertTrue(html.contains("vs. last month"))
    }
}
