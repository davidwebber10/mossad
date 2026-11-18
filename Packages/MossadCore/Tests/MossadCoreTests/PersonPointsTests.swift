import XCTest
@testable import MossadCore

/// A person's points belong to a 1:1 with that person: the rule for the three states of a meeting, where the points
/// show, the count line of a group meeting, and the check after a group call that notes a mention and closes nothing.
final class PersonPointsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "Dana Lee"

    private var people: [Person] {
        let me = Person(id: PersonID(rawValue: "p-dana"), displayName: owner, isOwner: true, origin: .owner, at: .distantPast)
        var sam = Person(id: PersonID(rawValue: "p-sam"), displayName: "Sam Carter", origin: .voiceNaming, at: .distantPast)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: .distantPast)]
        let jo = Person(id: PersonID(rawValue: "p-jo"), displayName: "Jo Park", origin: .voiceNaming, at: .distantPast)
        var old = Person(id: PersonID(rawValue: "p-old"), displayName: "Samuel Carter", origin: .voiceNaming, at: .distantPast)
        old.mergedInto = sam.id
        return [me, sam, jo, old]
    }

    private var refs: PersonReferences { PersonReferences(people: people) }
    private var directory: PersonDirectory {
        PersonDirectory([.init(name: owner, email: "dana@example.com"), .init(name: "Sam Carter", email: "sam@example.com"), .init(name: "Jo Park", email: nil)])
    }

    private func ofInvite(_ attendees: [String]) -> String? {
        OneOnOne.person(ofInvite: attendees, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
    }

    private func ofLive(_ r: CallRecord, voices: [String?]) -> String? {
        OneOnOne.person(ofLive: r, otherVoices: voices, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
    }

    private func liveRecord(attendees: [String] = [], title: String? = nil, notSure: Bool = false) -> CallRecord {
        var r = CallRecord(id: "live", platform: .meet, bundleID: "", start: now, end: now, status: .recording)
        r.attendees = attendees
        r.calendarTitle = title
        if notSure { r.inviteNotSure = true }
        return r
    }

    private func written(_ id: String, attendees: [String], voices: [String]) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), status: .written)
        r.calendarTitle = attendees.count > 2 ? "Product review" : "Sam and Dana"
        r.plannedStart = r.start
        r.plannedEnd = r.end
        r.attendees = attendees
        r.speakerNames["me:A"] = owner
        var lines = [Utterance(track: .me, speakerLabel: "A", start: 5, end: 9, text: "Hello, good to see you")]
        for (i, name) in voices.enumerated() {
            let label = String(UnicodeScalar(UInt8(66 + i)))
            r.speakerNames["them:\(label)"] = name
            lines.append(Utterance(track: .them, speakerLabel: label, start: Double(20 + i * 10), end: Double(25 + i * 10), text: "We should talk about the hiring plan for next quarter soon"))
        }
        r.utterances = lines
        return r
    }

    private let group = ["Dana Lee", "Sam Carter", "Jo Park", "Riley Moss", "Avery Webb", "Jordan Lee", "Casey Fox", "Morgan Hale"]

    // MARK: Rule 1: an upcoming invite

    func testAnInviteIsAOneOnOneWithOnePersonOnlyWhenThatOnePersonIsSurelySaved() {
        let table: [(attendees: [String], expected: String?)] = [
            (["Dana Lee", "Sam Carter"], "p-sam"),
            (["dana@example.com", "sam@example.com"], "p-sam"),
            (["Sam Carter"], "p-sam"),
            (group, nil),
            (["Dana Lee", "Sam Carter", "Jo Park"], nil),
            // Someone who is not surely saved, or a group address: not known who they are.
            (["Dana Lee", "riley@example.org"], nil),
            (["Dana Lee", "team@example.com"], nil),
            // A second entry that is not a saved person is still a second person.
            (["Dana Lee", "Sam Carter", "riley@example.org"], nil),
            (["Dana Lee"], nil),
            ([], nil),
        ]
        for row in table { XCTAssertEqual(ofInvite(row.attendees), row.expected, "\(row.attendees)") }
    }

    // MARK: Rule 1: the call that records now

    func testALiveCallWithASureInviteFollowsTheInvite() {
        XCTAssertEqual(ofLive(liveRecord(attendees: ["Dana Lee", "Sam Carter"], title: "Sam and Dana"), voices: []), "p-sam")
        XCTAssertNil(ofLive(liveRecord(attendees: group, title: "Product review"), voices: ["Sam Carter"]))
        // An invite that is not surely the call's: Mossad does not know.
        XCTAssertNil(ofLive(liveRecord(attendees: ["Dana Lee", "Sam Carter"], title: "Sam and Dana", notSure: true), voices: ["Sam Carter"]))
        // An invite with nobody else on it is no 1:1 either, whatever is heard.
        XCTAssertNil(ofLive(liveRecord(attendees: [], title: "Focus time"), voices: ["Sam Carter"]))
    }

    func testALiveCallWithNoInviteIsAOneOnOneOnlyWithOneOtherNamedVoice() {
        let table: [(voices: [String?], expected: String?)] = [
            (["Sam Carter"], "p-sam"),
            // The same person in two sessions of the stream: one voice.
            (["Sam Carter", "Sam Carter"], "p-sam"),
            (["Sam Carter", "Jo Park"], nil),
            // A voice with no name may be anyone.
            (["Sam Carter", nil], nil),
            ([nil], nil),
            ([], nil),
            // A name that no saved person surely has.
            (["Riley Moss"], nil),
            // The owner's own voice on the call audio is not another person.
            (["Sam Carter", "Dana Lee"], "p-sam"),
        ]
        for row in table { XCTAssertEqual(ofLive(liveRecord(), voices: row.voices), row.expected, "\(row.voices)") }
    }

    func testTheLiveTranscriptGivesEachOtherVoiceOnceWithItsNameOfNow() throws {
        var t = LiveTranscript()
        func turn(_ order: Int, _ label: String?) -> Data {
            var json: [String: Any] = ["type": "Turn", "turn_order": order, "end_of_turn": true, "transcript": "Hello there"]
            if let label { json["speaker_label"] = label }
            return try! JSONSerialization.data(withJSONObject: json)
        }
        t.apply(turn(0, "A"), source: .them, at: 1)
        t.apply(turn(1, "A"), source: .them, at: 2)
        t.apply(turn(0, nil), source: .me, at: 3)
        // Two short lines with no name: a stray label, no voice yet (`PersonPointsReviewTests` has the 10 s rule).
        XCTAssertEqual(t.otherVoices(owner: owner), [])
        t.names["0A"] = "Sam Carter"
        XCTAssertEqual(t.otherVoices(owner: owner), ["Sam Carter"])
        t.apply(turn(2, "B"), source: .them, at: 4)
        t.names["0B"] = owner
        // The owner heard on the call audio is not another voice.
        XCTAssertEqual(t.otherVoices(owner: owner), ["Sam Carter"])
        t.apply(turn(3, "C"), source: .them, at: 5)
        XCTAssertEqual(t.otherVoices(owner: owner), ["Sam Carter"])
        t.names["0C"] = "Jo Park"
        XCTAssertEqual(t.otherVoices(owner: owner), ["Sam Carter", "Jo Park"])
    }

    // MARK: Rule 1: a recording that ended

    func testARecordingIsAOneOnOneByTheRuleOfTheCheck() {
        let one = written("c1", attendees: ["Dana Lee", "Sam Carter"], voices: ["Sam Carter"])
        XCTAssertEqual(OneOnOne.person(ofRecording: one, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs), "p-sam")
        let many = written("c2", attendees: group, voices: ["Sam Carter", "Jo Park"])
        XCTAssertNil(OneOnOne.person(ofRecording: many, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs))
    }

    // MARK: Rule 2 and 3: where a person's points show

    func testAGroupMeetingShowsNoPersonPointsAndCountsThemInstead() {
        var book = NextTimeBook()
        for text in ["Hiring plan", "Role of the new lead", "Offsite", "Budget", "Review cycle"] {
            book.add(text, personID: "p-sam", personName: "Sam Carter", at: now)
        }
        book.add("Ask about the move", personID: "p-old", personName: "Samuel Carter", at: now)
        book.add("Launch date", personID: "p-jo", personName: "Jo Park", at: now)
        let canonical = refs.canonical
        // A group meeting: none of their points, a count for each person who has some.
        XCTAssertTrue(book.points(for: nil, oneOnOne: nil, canonical: canonical).isEmpty)
        let counts = book.personCounts(["p-sam", "p-jo", "p-riley"], oneOnOne: nil, canonical: canonical)
        XCTAssertEqual(counts.map(\.person), ["p-sam", "p-jo"])
        XCTAssertEqual(counts.map(\.count), [6, 1])
        // The 1:1 with Sam: all six of Sam's, a merged person's too, and no count for Sam.
        XCTAssertEqual(book.points(for: nil, oneOnOne: "p-sam", canonical: canonical).count, 6)
        XCTAssertTrue(book.personCounts(["p-sam"], oneOnOne: "p-sam", canonical: canonical).isEmpty)
    }

    func testTheLiveListHasThePersonsPointsOnlyInTheOneOnOne() {
        var book = NextTimeBook()
        let sam = book.add("Hiring plan", personID: "p-sam", personName: "Sam Carter", at: now)!
        XCTAssertTrue(LivePoints.list(book, series: nil, oneOnOne: nil, callID: "live").isEmpty)
        XCTAssertEqual(LivePoints.list(book, series: nil, oneOnOne: "p-sam", callID: "live").map(\.id), [sam.id])
        XCTAssertTrue(LivePoints.list(book, series: nil, oneOnOne: "p-jo", callID: "live").isEmpty)
    }

    // MARK: Rule 4: the check after a call

    func testAGroupRecordingStillReadsThePersonsPointsButOnlyNotesAMention() {
        var book = NextTimeBook()
        let p = book.add("Hiring plan for next quarter", personID: "p-sam", personName: "Sam Carter", at: now.addingTimeInterval(-86_400))!
        let r = written("g", attendees: group, voices: ["Sam Carter", "Jo Park"])
        // The same request as before: the point is read, so a mention can be found.
        let checked = NextTimeRules.points(for: r, in: book, series: nil, people: refs)
        XCTAssertEqual(checked.map(\.id), [p.id])
        let found = [NextTimeChecker.Found(point: p.id, at: 20, quote: "talk about the hiring plan for next quarter")]
        let other = NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
        XCTAssertNil(other)
        NextTimeRules.apply(found, checked: checked, call: r, to: &book, at: now, onlyOther: other, canonical: refs.canonical)
        let after = book.points.first { $0.id == p.id }!
        XCTAssertTrue(after.isOpen)
        XCTAssertNil(after.done)
        XCTAssertEqual(after.mentions?.map(\.callID), ["g"])
        XCTAssertEqual(after.mentions?.first?.quote, "talk about the hiring plan for next quarter")
        XCTAssertEqual(book.mentioned(in: "g").map(\.id), [p.id])
        XCTAssertTrue(book.checked.contains("g"))
    }

    func testTheOneOnOneRecordingClosesThePersonsPoint() {
        var book = NextTimeBook()
        let p = book.add("Hiring plan for next quarter", personID: "p-old", personName: "Samuel Carter", at: now.addingTimeInterval(-86_400))!
        let r = written("one", attendees: ["Dana Lee", "Sam Carter"], voices: ["Sam Carter"])
        let checked = NextTimeRules.points(for: r, in: book, series: nil, people: refs)
        let found = [NextTimeChecker.Found(point: p.id, at: 20, quote: "talk about the hiring plan for next quarter")]
        let other = NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ["dana@example.com"], people: refs)
        NextTimeRules.apply(found, checked: checked, call: r, to: &book, at: now, onlyOther: other, canonical: refs.canonical)
        let after = book.points.first { $0.id == p.id }!
        XCTAssertEqual(after.done?.callID, "one")
        XCTAssertNil(after.mentions)
    }

    func testAMeetingPointAndASeriesPointStillCloseInAGroupRecording() {
        var book = NextTimeBook()
        let r = written("g", attendees: group, voices: ["Sam Carter", "Jo Park"])
        let s = MeetingSeries(id: "cal:review", keys: ["cal:review"], title: "Product review", meetings: [], upcoming: [], cadence: nil, recurringInCalendar: true, usualPeople: [])
        let sp = book.add("Ship date for the next release", series: s, at: now.addingTimeInterval(-86_400))!
        let mp = book.add("Agenda for the review", meeting: NextTimeMeeting(MeetingDetail(title: "Product review", start: r.start, end: r.end)),
                          at: now.addingTimeInterval(-86_400))!
        XCTAssertEqual(Set(NextTimeRules.points(for: r, in: book, series: s, people: refs).map(\.id)), [sp.id, mp.id])
        let found = [NextTimeChecker.Found(point: sp.id, at: 20, quote: "talk about the hiring plan for next quarter"),
                     NextTimeChecker.Found(point: mp.id, at: 30, quote: "talk about the hiring plan for next quarter")]
        NextTimeRules.apply(found, checked: [sp, mp], call: r, to: &book, at: now, onlyOther: nil, canonical: refs.canonical)
        XCTAssertEqual(book.points.first { $0.id == sp.id }?.done?.callID, "g")
        XCTAssertEqual(book.points.first { $0.id == mp.id }?.done?.callID, "g")
    }

    // MARK: The words of a mention

    func testAMentionSaysWhichMeetingItCameUpIn() {
        let r = written("g", attendees: group, voices: ["Sam Carter", "Jo Park"])
        let m = NextTimePoint.Mention(callID: "g", at: 20, quote: "q", date: r.start)
        XCTAssertTrue(m.note(meeting: r).hasPrefix("Came up on "))
        XCTAssertTrue(m.note(meeting: r).hasSuffix(" in Product review"))
        var notes = r
        notes.source = CallRecord.geminiNotesSource
        notes.utterances = notes.utterances.filter { $0.track == .them }
        XCTAssertTrue(m.note(meeting: notes).hasSuffix(", in a meeting Mossad has only the notes of"))
        XCTAssertTrue(m.note(meeting: nil).hasSuffix(" in a meeting"))
    }
}
