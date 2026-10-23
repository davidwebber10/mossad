import XCTest
@testable import MossadCore

final class CallMetricsTests: XCTestCase {
    /// `turns` are (track, label, start, end, words).
    private func record(_ turns: [(Track, String, TimeInterval, TimeInterval, Int)], names: [String: String]) -> CallRecord {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "", start: Date(), end: Date().addingTimeInterval(1800), status: .written)
        r.speakerNames = names
        r.utterances = turns.map { Utterance(track: $0.0, speakerLabel: $0.1, start: $0.2, end: $0.3, text: Array(repeating: "word", count: $0.4).joined(separator: " ")) }
        return r
    }

    private let pair = ["me:A": "Dana", "them:A": "Jon"]

    func testOneOnOneTalkShareGoalIsUpToHalf() {
        let r = record([(.me, "A", 0, 60, 180), (.them, "A", 60, 100, 100)], names: pair)
        let m = CallMetrics(record: r, owner: "Dana", history: [])
        let share = m.check(.talkShare)!
        XCTAssertEqual(share.value, 0.6, accuracy: 0.001)
        XCTAssertEqual(share.goal, "Up to 50% in a 1:1")
        XCTAssertEqual(share.status, .over)
    }

    func testGroupTalkShareGoalIsOneAndAHalfFairShares() {
        let names = ["me:A": "Dana", "them:A": "Jon", "them:B": "Ana", "them:C": "Li"]
        let r = record([(.me, "A", 0, 90, 270), (.them, "A", 90, 180, 270), (.them, "B", 180, 270, 270), (.them, "C", 270, 360, 270)], names: names)
        let share = CallMetrics(record: r, owner: "Dana", history: []).check(.talkShare)!
        XCTAssertEqual(share.goal, "Up to 38% with 4 people")
        XCTAssertEqual(share.status, .good)
    }

    func testOwnersBackToBackLinesCountAsOneTurn() {
        // Two lines with a 1 s gap make one 150 s turn: over the 2 minute goal.
        let r = record([(.me, "A", 0, 70, 200), (.me, "A", 71, 150, 200), (.them, "A", 150, 400, 600)], names: pair)
        let m = CallMetrics(record: r, owner: "Dana", history: [])
        XCTAssertEqual(m.check(.longestTurn)!.value, 150)
        XCTAssertEqual(m.check(.longestTurn)!.status, .over)
        XCTAssertEqual(m.longTurns.map(\.start), [0])
    }

    func testPaceIsFlaggedOnlyWhenFarAboveTheOwnersUsual() {
        let r = record([(.me, "A", 0, 60, 200), (.them, "A", 60, 200, 300)], names: pair)
        var usual = DeliveryStats(record: r, owner: "Dana")
        usual.wordsPerMinute = 190
        XCTAssertEqual(CallMetrics(record: r, owner: "Dana", history: [usual]).check(.pace)!.status, .good)
        usual.wordsPerMinute = 160
        XCTAssertEqual(CallMetrics(record: r, owner: "Dana", history: [usual]).check(.pace)!.status, .over, "200 is over 15% above 160")
    }

    func testQuestionsCompareWithTheUsualCount() {
        var r = record([(.me, "A", 0, 90, 60), (.them, "A", 90, 200, 300)], names: pair)
        r.utterances[0].text = "Why? And when? Ok."
        var usual = DeliveryStats(record: r, owner: "Dana")
        usual.questions = 5
        let q = CallMetrics(record: r, owner: "Dana", history: [usual, usual]).check(.questions)!
        XCTAssertEqual(q.value, 1)
        XCTAssertEqual(q.usual, 5)
    }

    func testTimelineHasAShareForEachThreeMinutes() {
        let r = record([(.me, "A", 0, 90, 300), (.them, "A", 90, 180, 300), (.them, "A", 180, 360, 300)], names: pair)
        let m = CallMetrics(record: r, owner: "Dana", history: [])
        XCTAssertEqual(m.timeline.count, 2)
        XCTAssertEqual(m.timeline[0].share, 0.5, accuracy: 0.001)
        XCTAssertEqual(m.timeline[1].share, 0, accuracy: 0.001)
        XCTAssertEqual(m.timeline[0].wordsPerMinute!, 200, accuracy: 0.5)
        XCTAssertNil(m.timeline[1].wordsPerMinute)
    }

    func testAListenerGetsNoChecks() {
        let r = record([(.me, "A", 0, 20, 40), (.them, "A", 20, 1000, 2000)], names: pair)
        XCTAssertTrue(CallMetrics(record: r, owner: "Dana", history: []).checks.isEmpty)
    }
}
