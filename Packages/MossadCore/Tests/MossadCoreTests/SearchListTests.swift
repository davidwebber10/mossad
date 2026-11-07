import XCTest
@testable import MossadCore

final class SearchListTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func meetingHit(_ id: String) -> MeetingHit {
        MeetingHit(callID: id, title: SearchText(id), start: now, end: now.addingTimeInterval(1800), platform: .zoom,
                   kind: nil, tags: [], context: nil, score: 1)
    }

    func personHit(_ name: String) -> PersonHit {
        PersonHit(name: SearchText(name), email: nil, isOwner: false, meetings: 3, lastMet: now, score: 1)
    }

    func moment(_ callID: String, _ turn: Int) -> MomentHit {
        MomentHit(callID: callID, meetingTitle: callID, meetingStart: now, turn: turn, speaker: "Ann",
                  time: Double(turn * 10), snippet: SearchText("x"), score: 1)
    }

    func results() -> SearchResults {
        var r = SearchResults()
        r.query = "x"
        r.topHit = .meeting(meetingHit("top"))
        r.meetings = [meetingHit("m1"), meetingHit("m2")]
        r.people = [personHit("Ann Lee")]
        r.moments = [
            MomentGroup(callID: "c1", title: "c1", start: now, moments: [moment("c1", 1), moment("c1", 4)], moreCount: 2),
            MomentGroup(callID: "c2", title: "c2", start: now, moments: [moment("c2", 0)], moreCount: 0),
        ]
        return r
    }

    func testRowsFollowTheGroupsWithAMoreRowAfterAMeetingsMoments() {
        let list = SearchList(results: results())
        XCTAssertEqual(list.sections.map(\.title), ["Top hit", "Meetings", "People", "Transcript"])
        XCTAssertEqual(list.rowIDs, ["meeting:top", "meeting:m1", "meeting:m2", "person:Ann Lee",
                                     "moment:c1#1", "moment:c1#4", "more:c1", "moment:c2#0"])
        XCTAssertEqual(list.row("more:c1"), .more(callID: "c1", count: 2))
        XCTAssertEqual(list.first, "meeting:top")
    }

    func testAnExpandedMeetingShowsEveryMomentAndNoMoreRow() {
        let all = [moment("c1", 1), moment("c1", 2), moment("c1", 4), moment("c1", 9)]
        let list = SearchList(results: results(), expanded: ["c1": all])
        XCTAssertEqual(Array(list.rowIDs.suffix(5)), ["moment:c1#1", "moment:c1#2", "moment:c1#4", "moment:c1#9", "moment:c2#0"])
    }

    func testAnExpandedMeetingLeavesOutTheTopHitMoment() {
        var r = results()
        r.topHit = .moment(moment("c1", 2))
        let all = [moment("c1", 1), moment("c1", 2), moment("c1", 4)]
        let list = SearchList(results: r, expanded: ["c1": all])
        XCTAssertEqual(list.rowIDs.filter { $0 == "moment:c1#2" }.count, 1)
        XCTAssertEqual(list.rowIDs.first, "moment:c1#2")
    }

    func testArrowsMoveAcrossGroupsAndStopAtTheEnds() {
        let list = SearchList(results: results())
        XCTAssertEqual(list.moved(nil, by: 1), "meeting:top")
        XCTAssertEqual(list.moved("meeting:m2", by: 1), "person:Ann Lee")
        XCTAssertEqual(list.moved("person:Ann Lee", by: -1), "meeting:m2")
        XCTAssertEqual(list.moved("meeting:top", by: -1), "meeting:top")
        XCTAssertEqual(list.moved("moment:c2#0", by: 1), "moment:c2#0")
        // A selection that left the list starts again at the top.
        XCTAssertEqual(list.moved("gone", by: 1), "meeting:top")
    }

    func testTabMovesToTheNextGroupAndWraps() {
        let list = SearchList(results: results())
        XCTAssertEqual(list.nextSection(after: "meeting:top"), "meeting:m1")
        XCTAssertEqual(list.nextSection(after: "meeting:m2"), "person:Ann Lee")
        XCTAssertEqual(list.nextSection(after: "moment:c1#4"), "meeting:top")
        XCTAssertEqual(list.nextSection(after: "meeting:m2", backward: true), "meeting:top")
        XCTAssertEqual(list.nextSection(after: "meeting:top", backward: true), "moment:c1#1")
        XCTAssertEqual(list.nextSection(after: nil), "meeting:top")
    }

    func testSuggestionsListRecentMeetingsThenPeople() {
        let s = SearchSuggestions(meetings: [meetingHit("a"), meetingHit("b")], people: [personHit("Bo Chen")], tags: ["Budget"])
        let list = SearchList(suggestions: s)
        XCTAssertEqual(list.sections.map(\.title), ["Recent meetings", "People you meet most"])
        XCTAssertEqual(list.rowIDs, ["meeting:a", "meeting:b", "person:Bo Chen"])
    }

    func testEmptyResultsHaveNoRows() {
        let list = SearchList(results: .empty)
        XCTAssertTrue(list.sections.isEmpty)
        XCTAssertNil(list.first)
        XCTAssertNil(list.moved(nil, by: 1))
        XCTAssertNil(list.nextSection(after: nil))
    }

    func testCountsForVoiceOver() {
        XCTAssertEqual(SearchList(results: results()).announcement, "7 results")
        XCTAssertEqual(SearchList(results: .empty).announcement, "No results")
        var one = SearchResults()
        one.meetings = [meetingHit("m1")]
        XCTAssertEqual(SearchList(results: one).announcement, "1 result")
    }
}
