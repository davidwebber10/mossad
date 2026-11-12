import XCTest
@testable import MossadCore

final class PeopleSortTests: XCTestCase {
    func profile(_ name: String, owner: Bool = false, samples: Int = 1) -> VoiceProfile {
        VoiceProfile(name: name, isOwner: owner, embeddings: Array(repeating: [0.1], count: samples))
    }

    func meeting(_ id: String, _ start: TimeInterval, talk: TimeInterval) -> PersonMeeting {
        PersonMeeting(id: id, title: "t", platform: .meet, start: Date(timeIntervalSince1970: start), talk: talk, share: nil)
    }

    func stats(_ meetings: [PersonMeeting]) -> PersonStats {
        var s = PersonStats()
        s.meetings = meetings.sorted { $0.start > $1.start }
        return s
    }

    let people = ["Me Owner", "Dana Lee", "Sam Park", "Alex Rivera"]
    var profiles: [VoiceProfile] { [profile("Sam Park"), profile("Dana Lee"), profile("Me Owner", owner: true), profile("Alex Rivera")] }
    var table: [String: PersonStats] {
        [
            "Dana Lee": stats([meeting("a", 100, talk: 50), meeting("b", 400, talk: 50)]),
            "Sam Park": stats([meeting("c", 300, talk: 10)]),
            "Alex Rivera": stats([meeting("d", 200, talk: 500), meeting("e", 250, talk: 5), meeting("f", 260, talk: 5)]),
            "Me Owner": stats([meeting("g", 50, talk: 1)]),
        ]
    }

    func names(_ sort: PeopleSort) -> [String] { sort.order(profiles, stats: table).map(\.name) }

    func testOwnerIsFirstInEverySort() {
        for sort in [PeopleSort.recent, .mostMet, .talkTime, .newest, .firstName, .lastName] {
            XCTAssertEqual(names(sort).first, "Me Owner", "\(sort)")
        }
    }

    func testRecentByLastHeard() {
        XCTAssertEqual(names(.recent), ["Me Owner", "Dana Lee", "Sam Park", "Alex Rivera"])
    }

    func testMostMetByMeetingCount() {
        XCTAssertEqual(names(.mostMet), ["Me Owner", "Alex Rivera", "Dana Lee", "Sam Park"])
    }

    func testTalkTimeByTotalSeconds() {
        XCTAssertEqual(names(.talkTime), ["Me Owner", "Alex Rivera", "Dana Lee", "Sam Park"])
    }

    func testNewestByFirstMeetingNewestFirst() {
        // First meetings: Sam 300, Alex 200, Dana 100.
        XCTAssertEqual(names(.newest), ["Me Owner", "Sam Park", "Alex Rivera", "Dana Lee"])
    }

    func testFirstNameAToZ() {
        XCTAssertEqual(names(.firstName), ["Me Owner", "Alex Rivera", "Dana Lee", "Sam Park"])
    }

    func testLastNameAToZThenFirstName() {
        // Lee, Park, Rivera; two with one last name go by the first name; a single name is its own last name.
        let all = [profile("Sam Park"), profile("Dana Lee"), profile("Alex Rivera"), profile("Jo Park"), profile("Madonna")]
        XCTAssertEqual(PeopleSort.lastName.order(all, stats: [:]).map(\.name), ["Dana Lee", "Madonna", "Jo Park", "Sam Park", "Alex Rivera"])
    }

    func testASavedNameSortIsTheFirstNameSort() {
        XCTAssertEqual(PeopleSort(rawValue: "name"), .firstName)
    }

    func testTiesBreakByName() {
        let tied = [profile("Zed Z"), profile("Amy A")]
        XCTAssertEqual(PeopleSort.mostMet.order(tied, stats: [:]).map(\.name), ["Amy A", "Zed Z"])
    }

    func testNeedsVoiceSampleKeepsProfilesWithoutEmbeddings() {
        let all = [profile("Dana Lee", samples: 0), profile("Sam Park")]
        XCTAssertEqual(PeopleSort.needsVoiceSample(all).map(\.name), ["Dana Lee"])
    }
}
