import XCTest
@testable import MossadCore

final class PersonStatisticsTests: XCTestCase {
    func call(_ id: String, _ start: TimeInterval, _ names: [String: String], talk: [(String, TimeInterval)] = [],
              items: [ActionItem] = []) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: start),
                           end: Date(timeIntervalSince1970: start + 600), status: .written)
        r.speakerNames = names
        var t: TimeInterval = 0
        r.utterances = talk.map { key, seconds in
            let parts = key.split(separator: ":")
            defer { t += seconds }
            return Utterance(track: Track(rawValue: String(parts[0]))!, speakerLabel: String(parts[1]),
                             start: t, end: t + seconds, text: "x")
        }
        r.actionItems = items
        return r
    }

    func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testMeetingsNewestFirstWithFirstAndLastHeard() {
        let stats = PersonStatistics.compute([
            call("1", 100, ["me:A": "David Webber", "them:A": "Alex Rivera"]),
            call("2", 300, ["me:A": "David Webber"]),
            // Two keys with one name in a call still count as one meeting.
            call("3", 200, ["me:A": "David Webber", "them:A": "Alex Rivera", "them:B": "Alex Rivera"]),
            call("4", 400, [:]),
        ])
        XCTAssertEqual(Set(stats.keys), ["David Webber", "Alex Rivera"])
        XCTAssertEqual(stats["David Webber"]?.meetings.map(\.id), ["2", "3", "1"])
        XCTAssertEqual(stats["David Webber"]?.firstHeard, date(100))
        XCTAssertEqual(stats["David Webber"]?.lastHeard, date(300))
        XCTAssertEqual(stats["Alex Rivera"]?.meetings.map(\.id), ["3", "1"])
    }

    func testTalkTimeSumsEveryKeyWithTheName() {
        let stats = PersonStatistics.compute([
            call("1", 100, ["me:A": "David Webber", "them:A": "Alex Rivera", "them:B": "Alex Rivera"],
                 talk: [("me:A", 30), ("them:A", 10), ("them:B", 50), ("them:C", 10)]),
        ])
        let alex = stats["Alex Rivera"]!
        XCTAssertEqual(alex.meetings.first?.talk, 60)
        XCTAssertEqual(alex.totalTalk, 60)
        // 60 of the 100 seconds of speech, unnamed voices included.
        XCTAssertEqual(alex.meetings.first?.share ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(stats["David Webber"]?.totalTalk, 30)
    }

    func testAverageShareSkipsMeetingsWithNoSpeech() {
        let stats = PersonStatistics.compute([
            call("1", 100, ["me:A": "David Webber", "them:A": "Alex Rivera"], talk: [("me:A", 20), ("them:A", 80)]),
            call("2", 200, ["me:A": "David Webber", "them:A": "Alex Rivera"], talk: [("me:A", 60), ("them:A", 40)]),
            call("3", 300, ["me:A": "David Webber"]),
        ])
        let david = stats["David Webber"]!
        XCTAssertEqual(david.averageShare ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(david.totalTalk, 80)
        XCTAssertNil(david.meetings.first?.share)
    }

    func testOftenWithCountsSharedMeetings() {
        let stats = PersonStatistics.compute([
            call("1", 100, ["me:A": "David Webber", "them:A": "Alex Rivera", "them:B": "Sam Cole"]),
            call("2", 200, ["me:A": "David Webber", "them:A": "Alex Rivera"]),
            call("3", 300, ["me:A": "David Webber", "them:A": "Sam Cole", "them:B": "Sam Cole"]),
            call("4", 400, ["me:A": "David Webber", "them:A": "Jo Park"]),
        ])
        XCTAssertEqual(stats["David Webber"]?.oftenWith, [
            CoSpeaker(name: "Alex Rivera", meetings: 2), CoSpeaker(name: "Sam Cole", meetings: 2), CoSpeaker(name: "Jo Park", meetings: 1),
        ])
        XCTAssertEqual(stats["Alex Rivera"]?.oftenWith, [CoSpeaker(name: "David Webber", meetings: 2), CoSpeaker(name: "Sam Cole", meetings: 1)])
    }

    func testActionItemsMatchExactNameOrUniqueFirstName() {
        let stats = PersonStatistics.compute([
            call("1", 100, ["me:A": "David Webber", "them:A": "Alex Rivera"], items: [
                ActionItem(owner: "Alex Rivera", task: "Send the deck"),
                ActionItem(owner: "alex", task: "Book a room"),
                ActionItem(owner: "David", task: "Review"),
                ActionItem(owner: nil, task: "Nobody"),
            ]),
            // Two speakers named Alex: a first name alone is not enough.
            call("2", 200, ["them:A": "Alex Rivera", "them:B": "Alex Kim"], items: [
                ActionItem(owner: "Alex", task: "Ambiguous"),
                ActionItem(owner: "Alex Kim", task: "Exact"),
            ]),
            // Not a speaker in this call.
            call("3", 300, ["me:A": "David Webber"], items: [ActionItem(owner: "Alex Rivera", task: "Elsewhere")]),
        ])
        XCTAssertEqual(stats["Alex Rivera"]?.actionItems.map(\.item.task), ["Send the deck", "Book a room"])
        XCTAssertEqual(stats["Alex Rivera"]?.actionItems.first?.meetingID, "1")
        XCTAssertEqual(stats["Alex Kim"]?.actionItems.map(\.item.task), ["Exact"])
        XCTAssertEqual(stats["David Webber"]?.actionItems.map(\.item.task), ["Review"])
    }

    func testUnnamedSpeakersDoNotMatchByFirstWord() {
        let stats = PersonStatistics.compute([
            call("1", 100, ["them:A": "Speaker A"], items: [ActionItem(owner: "Speaker C", task: "x")]),
        ])
        XCTAssertEqual(stats["Speaker A"]?.actionItems, [])
    }

    func testNoRecordsGiveNoStats() {
        XCTAssertEqual(PersonStatistics.compute([]), [:])
    }
}
