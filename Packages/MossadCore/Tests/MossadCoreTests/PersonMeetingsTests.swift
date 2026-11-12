import XCTest
@testable import MossadCore

/// The person page's Meetings tab: every meeting with the person by the rule of the Meetings filter, and the
/// numbers of the page's top band.
final class PersonMeetingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private var people: MeetingFilterPeople {
        MeetingFilterPeople(directory: PersonDirectory([.init(name: "Sam Carter", email: "sam@example.com"), .init(name: "Riley Park", email: nil),
                                                        .init(name: "Dana Lee", email: "dana@example.com")]),
                            ids: ["Sam Carter": "id-sam", "Riley Park": "id-riley", "Dana Lee": "id-dana"], owner: "Dana Lee")
    }

    private func record(_ id: String, _ start: Date, minutes: Double = 30, names: [String: String] = [:], attendees: [String] = [],
                        title: String? = nil, platform: Platform = .meet, notesOnly: Bool = false, status: CallStatus = .written) -> CallRecord {
        var r = CallRecord(id: id, platform: platform, bundleID: "b", start: start, end: start.addingTimeInterval(minutes * 60), status: status)
        r.customTitle = title
        var t = 0.0
        for key in names.keys.sorted() {
            let parts = key.split(separator: ":")
            r.utterances.append(Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: t, end: t + 60, text: "Fine."))
            t += 61
        }
        r.speakerNames = names
        r.attendees = attendees
        if notesOnly { r.source = CallRecord.geminiNotesSource }
        return r
    }

    private let both = ["me:A": "Dana Lee", "them:A": "Sam Carter"]

    func testEveryMeetingWhereTheySpokeOrWereSurelyInvitedNewestFirst() {
        let records = [
            record("spoke", daysAgo(10), names: both),
            record("invited", daysAgo(3), names: ["me:A": "Dana Lee"], attendees: ["sam@example.com"]),
            record("other", daysAgo(2), names: ["me:A": "Dana Lee", "them:A": "Riley Park"]),
            record("unsure", daysAgo(1), names: ["me:A": "Dana Lee"], attendees: ["Sam"]),
            record("live", daysAgo(0), names: both, status: .recording),
        ]
        let m = PersonMeetings(records: records, name: "Sam Carter", people: people, now: now)
        XCTAssertEqual(m.rows.map(\.id), ["invited", "spoke"], "a first name alone on the invite is no sure match, and the call that records now waits")
        XCTAssertEqual(m.rows.map(\.part), [.invited, .spoke])
    }

    func testTheyFollowTheirIdThroughAnInviteUnderAnotherForm() {
        let r = record("a", daysAgo(1), names: ["me:A": "Dana Lee"], attendees: ["Carter, Sam"])
        XCTAssertEqual(PersonMeetings(records: [r], name: "Sam Carter", people: people, now: now).rows.map(\.id), ["a"])
    }

    func testARowCarriesTitleLengthPlatformAndTheNotesMark() {
        let r = record("a", daysAgo(1), minutes: 45, names: both, title: "Budget review", platform: .zoom, notesOnly: true)
        let row = PersonMeetings(records: [r], name: "Sam Carter", people: people, now: now).rows[0]
        XCTAssertEqual(row.title, "Budget review")
        XCTAssertEqual(row.seconds, 45 * 60)
        XCTAssertEqual(row.platform, .zoom)
        XCTAssertTrue(row.notesOnly)
    }

    func testTheOwnersOwnPageListsTheMeetingsTheOwnerSpokeIn() {
        let records = [record("a", daysAgo(2), names: both), record("b", daysAgo(1), names: ["them:A": "Sam Carter"])]
        let m = PersonMeetings(records: records, name: "Dana Lee", isOwner: true, people: people, now: now)
        XCTAssertEqual(m.rows.map(\.id), ["a"])
    }

    // MARK: Together

    func testTogetherCountsOnlyMeetingsTheySpokeInWithTheOwnerThere() {
        let records = [
            record("a", daysAgo(40), minutes: 30, names: both),
            record("b", daysAgo(20), minutes: 60, names: both),
            record("invited", daysAgo(5), minutes: 30, names: ["me:A": "Dana Lee"], attendees: ["sam@example.com"]),
            // A notes-only meeting where the owner has no line: the owner may have missed it.
            record("missed", daysAgo(3), minutes: 30, names: ["them:A": "Sam Carter"], notesOnly: true),
        ]
        let t = PersonMeetings(records: records, name: "Sam Carter", people: people, now: now).together
        XCTAssertEqual(t.meetings, 4)
        XCTAssertEqual(t.invitedOnly, 1)
        XCTAssertEqual(t.met, 2)
        XCTAssertEqual(t.lastMet, daysAgo(20), "an invite does not prove that they came")
        XCTAssertEqual(t.seconds, 90 * 60)
        XCTAssertEqual(t.recent, 2)
    }

    func testCadenceFromTheLast90Days() {
        func cadence(_ days: [Double]) -> PersonMeetings.Cadence? {
            PersonMeetings(records: days.enumerated().map { record("\($0.offset)", daysAgo($0.element), names: both) },
                           name: "Sam Carter", people: people, now: now).together.cadence
        }
        XCTAssertEqual(cadence([1, 8, 15, 22, 29]), .weekly)
        XCTAssertEqual(cadence([2, 16, 30, 44]), .everyOtherWeek)
        XCTAssertEqual(cadence([5, 35, 65]), .monthly)
        XCTAssertEqual(cadence([1, 2, 3, 4]), .daily)
        XCTAssertNil(cadence([1, 8]), "two meetings are no rhythm")
        XCTAssertNil(cadence([60, 67, 74, 81]), "weekly once, and nothing for two months: no rhythm now")
        XCTAssertNil(cadence([100, 107, 114]), "nothing in the last 90 days")
    }

    // MARK: Search

    func testSearchMatchesEveryWordInTheTitleTagsPlatformOrNotesMark() {
        var tagged = record("a", daysAgo(1), names: both, title: "Budget review", platform: .zoom)
        tagged.tags = ["Databricks"]
        let notes = record("b", daysAgo(2), names: both, title: "Weekly sync", notesOnly: true)
        let m = PersonMeetings(records: [tagged, notes], name: "Sam Carter", people: people, now: now)
        XCTAssertEqual(m.matching("").map(\.id), ["a", "b"])
        XCTAssertEqual(m.matching("budget").map(\.id), ["a"])
        XCTAssertEqual(m.matching("REVIEW zoom").map(\.id), ["a"])
        XCTAssertEqual(m.matching("databricks").map(\.id), ["a"])
        XCTAssertEqual(m.matching("gemini").map(\.id), ["b"])
        XCTAssertEqual(m.matching("budget weekly").map(\.id), [])
    }

    // MARK: The iPhone's people

    func testTheSyncedPeopleGiveTheSameRule() {
        var sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: now)
        sam.addEmail("sam@example.com", state: .verified, source: .voiceNaming, at: now)
        var owner = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", isOwner: true, origin: .owner, at: now)
        owner.addEmail("dana@example.com", state: .verified, source: .owner, at: now)
        var gone = Person(id: PersonID(rawValue: "id-old"), displayName: "Old Name", origin: .voiceNaming, at: now)
        gone.deleted = now
        let phone = MeetingFilterPeople(people: [sam, owner, gone], owner: "Dana Lee")
        XCTAssertEqual(phone.ids, ["Sam Carter": "id-sam", "Dana Lee": "id-dana"])
        let r = record("a", daysAgo(1), names: ["me:A": "Dana Lee"], attendees: ["sam@example.com"])
        XCTAssertEqual(PersonMeetings(records: [r], name: "Sam Carter", people: phone, now: now).rows.map(\.part), [.invited])
    }
}
